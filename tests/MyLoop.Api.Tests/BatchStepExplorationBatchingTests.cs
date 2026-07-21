using System.Data.Common;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Models;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #107 (ML-ERR-010): ProcessBatchStepClaim awaited a per-point
/// RecordExploration upsert — up to 200 sequential round-trips inside the serializable
/// transaction, adding seconds of pure RTT latency on cloud Postgres and inflating the
/// serialization-conflict window for everyone in the region. The whole batch must record
/// exploration with ONE ExploredCells statement (the loop path's RecordExplorationBatch),
/// with the same newExplorations total (distinct new cells this batch) feeding the
/// ExploreNewArea mission.
/// </summary>
public class BatchStepExplorationBatchingTests : IAsyncLifetime
{
    private readonly PostgreSqlContainer _pg = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .Build();

    private string _conn = "";

    public async Task InitializeAsync()
    {
        await _pg.StartAsync();
        _conn = _pg.GetConnectionString();
        await using var db = NewDb(new ExploredCellsInsertCounter());
        await db.Database.EnsureCreatedAsync();
    }

    public async Task DisposeAsync() => await _pg.DisposeAsync();

    /// <summary>Counts INSERT statements that target the ExploredCells table.</summary>
    private sealed class ExploredCellsInsertCounter : DbCommandInterceptor
    {
        public int Inserts;

        public override InterceptionResult<int> NonQueryExecuting(
            DbCommand command, CommandEventData eventData, InterceptionResult<int> result)
        {
            Count(command);
            return result;
        }

        public override ValueTask<InterceptionResult<int>> NonQueryExecutingAsync(
            DbCommand command, CommandEventData eventData, InterceptionResult<int> result,
            CancellationToken cancellationToken = default)
        {
            Count(command);
            return new ValueTask<InterceptionResult<int>>(result);
        }

        private void Count(DbCommand command)
        {
            if (command.CommandText.Contains("INSERT") && command.CommandText.Contains("ExploredCells"))
                Interlocked.Increment(ref Inserts);
        }
    }

    private AppDbContext NewDb(ExploredCellsInsertCounter counter) =>
        new(new DbContextOptionsBuilder<AppDbContext>()
            .UseNpgsql(_conn)
            .AddInterceptors(counter)
            .Options);

    // Deterministic cell mapping (cellId = round(lat * 1000)) — distinct lats give distinct cells.
    private static long CellOf(double lat) => (long)Math.Round(lat * 1000);

    private static (TerritoryService Service, Mock<IMissionService> Missions) NewService(AppDbContext db)
    {
        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.GetCellAtPoint(It.IsAny<double>(), It.IsAny<double>()))
            .Returns<double, double>((lat, lng) => new HexCell { CellId = CellOf(lat), Boundary = [[lat, lng]] });
        hex.Setup(h => h.GetCellCenter(It.IsAny<long>())).Returns(new GeoCoordinate { Lat = 12.9, Lng = 77.5 });
        hex.Setup(h => h.GetParentCellId(It.IsAny<long>())).Returns(1L);
        hex.Setup(h => h.GetNeighborhoodId(It.IsAny<long>())).Returns(2L);
        hex.Setup(h => h.CalculateArea(It.IsAny<int>())).Returns<int>(c => c * GameConstants.CellAreaSquareMeters);

        var geo = new Mock<IGeoService>();
        geo.Setup(g => g.CalculatePathDistance(It.IsAny<double[][]>())).Returns(250.0);

        var notifier = new Mock<ITerritoryNotifier> { DefaultValue = DefaultValue.Empty };
        var push = new Mock<IPushNotificationService> { DefaultValue = DefaultValue.Empty };
        var missions = new Mock<IMissionService> { DefaultValue = DefaultValue.Empty };
        missions.Setup(m => m.AwardXp(It.IsAny<Guid>(), It.IsAny<int>(), It.IsAny<string>()))
            .ReturnsAsync(new XpGainResult { TotalXp = 0, Level = 1, LeveledUp = false });
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };
        achievements.Setup(a => a.CheckAndUnlock(It.IsAny<Guid>()))
            .ReturnsAsync(new List<AchievementUnlock>());

        var service = new TerritoryService(
            db, hex.Object, geo.Object, notifier.Object, Mock.Of<IPathValidationService>(),
            push.Object, new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, Mock.Of<IServiceScopeFactory>(), NullLogger<TerritoryService>.Instance);
        return (service, missions);
    }

    private static List<BatchStepPoint> Batch(params double[] lats) =>
        lats.Select((lat, i) => new BatchStepPoint
        {
            ClientId = $"{lat}_{i}",
            Lat = lat,
            Lng = 77.5,
            CapturedAt = DateTime.UtcNow,
        }).ToList();

    private static double[] FiftyDistinctLats() =>
        Enumerable.Range(1, 50).Select(i => 1.0 + i / 1000.0).ToArray();

    private async Task SeedUser(Guid userId)
    {
        await using var seed = NewDb(new ExploredCellsInsertCounter());
        seed.Users.Add(new User
        {
            Id = userId,
            FirebaseUid = $"uid-{userId}",
            DisplayName = "U",
            Color = "#111111",
        });
        await seed.SaveChangesAsync();
    }

    [Fact]
    public async Task Fifty_new_cells_record_exploration_in_one_statement_with_the_full_count()
    {
        var userId = Guid.NewGuid();
        await SeedUser(userId);

        var counter = new ExploredCellsInsertCounter();
        Mock<IMissionService> missions;
        await using (var db = NewDb(counter))
        {
            (var service, missions) = NewService(db);
            var response = await service.ProcessBatchStepClaim(
                userId, null, Batch(FiftyDistinctLats()), Guid.NewGuid());
            Assert.Null(response.RejectionReason);
        }

        // The whole batch is one ExploredCells round-trip, not one per point.
        Assert.Equal(1, counter.Inserts);

        // All 50 distinct cells were recorded and the full count fed the ExploreNewArea mission.
        await using var check = NewDb(new ExploredCellsInsertCounter());
        Assert.Equal(50, await check.ExploredCells.CountAsync(e => e.UserId == userId));
        missions.Verify(
            m => m.RecordProgress(userId, MissionType.ExploreNewArea, 50, It.IsAny<DateOnly?>()),
            Times.Once);
    }

    [Fact]
    public async Task Repeat_batch_over_owned_cells_adds_no_rows_and_stays_one_statement()
    {
        var userId = Guid.NewGuid();
        await SeedUser(userId);
        var lats = FiftyDistinctLats();

        await using (var db = NewDb(new ExploredCellsInsertCounter()))
            await NewService(db).Service.ProcessBatchStepClaim(userId, null, Batch(lats), Guid.NewGuid());

        // Second identical walk: every cell is now owned ("owned" skip branch), which must
        // still refresh exploration through the same single batched statement.
        var counter = new ExploredCellsInsertCounter();
        Mock<IMissionService> missions;
        await using (var db = NewDb(counter))
        {
            (var service, missions) = NewService(db);
            var response = await service.ProcessBatchStepClaim(userId, null, Batch(lats), Guid.NewGuid());
            Assert.Null(response.RejectionReason);
        }

        Assert.Equal(1, counter.Inserts);

        // No duplicate exploration rows, and no ExploreNewArea progress for zero new cells.
        await using var check = NewDb(new ExploredCellsInsertCounter());
        Assert.Equal(50, await check.ExploredCells.CountAsync(e => e.UserId == userId));
        missions.Verify(
            m => m.RecordProgress(userId, MissionType.ExploreNewArea, It.IsAny<int>(), It.IsAny<DateOnly?>()),
            Times.Never);
    }
}
