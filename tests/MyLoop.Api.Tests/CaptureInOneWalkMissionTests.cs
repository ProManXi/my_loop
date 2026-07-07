using Microsoft.EntityFrameworkCore;
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
/// Regression tests for issue #108 (ML-ERR-011): the CaptureInOneWalk mission accumulated across
/// separate walks (RecordProgress did CurrentProgress += amount for every type), so several small
/// walks could complete a "capture N in ONE walk" mission. It must instead track the maximum of a
/// single walk's total. One walk = one Claim (#56), so each walk's cumulative captured count is its
/// Claim.CellCount; the mission progress is the max of that across the day's walks.
/// </summary>
public class CaptureInOneWalkMissionTests : IAsyncLifetime
{
    private readonly PostgreSqlContainer _pg = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .Build();

    private string _conn = "";

    public async Task InitializeAsync()
    {
        await _pg.StartAsync();
        _conn = _pg.GetConnectionString();
        await using var db = NewDb();
        await db.Database.EnsureCreatedAsync();
    }

    public async Task DisposeAsync() => await _pg.DisposeAsync();

    private AppDbContext NewDb() =>
        new(new DbContextOptionsBuilder<AppDbContext>().UseNpgsql(_conn).Options);

    // Deterministic cell mapping (cellId = round(lat * 1000)) — distinct lats give distinct cells.
    private static long CellOf(double lat) => (long)Math.Round(lat * 1000);

    private static TerritoryService NewService(AppDbContext db)
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
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };
        achievements.Setup(a => a.CheckAndUnlock(It.IsAny<Guid>()))
            .ReturnsAsync(new List<AchievementUnlock>());

        // The REAL MissionService — this is the unit under test on the mission side. It shares the
        // same AppDbContext as the territory service so its writes land in one transaction.
        var missions = new MissionService(db);

        return new TerritoryService(
            db, hex.Object, geo.Object, notifier.Object, Mock.Of<IPathValidationService>(),
            push.Object, new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions, achievements.Object, NullLogger<TerritoryService>.Instance);
    }

    private static List<BatchStepPoint> Batch(params double[] lats) =>
        lats.Select((lat, i) => new BatchStepPoint
        {
            ClientId = $"{lat}_{i}",
            Lat = lat,
            Lng = 77.5,
            CapturedAt = DateTime.UtcNow,
        }).ToList();

    private async Task SeedUser(Guid userId)
    {
        await using var seed = NewDb();
        seed.Users.Add(new User { Id = userId, FirebaseUid = $"uid-{userId}", DisplayName = "U", Color = "#111111" });
        await seed.SaveChangesAsync();
    }

    /// <summary>Seeds a single CaptureInOneWalk mission for today so progress is deterministic
    /// (rather than depending on the random adaptive-mission generator).</summary>
    private async Task SeedCaptureInOneWalkMission(Guid userId, int target)
    {
        await using var seed = NewDb();
        seed.DailyMissions.Add(new DailyMission
        {
            Id = Guid.NewGuid(),
            UserId = userId,
            Date = DateOnly.FromDateTime(DateTime.UtcNow),
            Type = MissionType.CaptureInOneWalk,
            TargetValue = target,
            CurrentProgress = 0,
            XpReward = 50,
            Description = "Capture in one walk",
        });
        await seed.SaveChangesAsync();
    }

    private async Task<DailyMission> GetMission(Guid userId)
    {
        await using var db = NewDb();
        return await db.DailyMissions.SingleAsync(
            m => m.UserId == userId && m.Type == MissionType.CaptureInOneWalk);
    }

    [Fact]
    public async Task Progress_is_the_max_single_walk_total_not_the_sum_across_walks()
    {
        var userId = Guid.NewGuid();
        await SeedUser(userId);
        await SeedCaptureInOneWalkMission(userId, target: 8);

        // Walk A (session s1): two batches, 3 + 3 = 6 cells in one walk.
        var s1 = Guid.NewGuid();
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.001, 1.002, 1.003), s1);
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.004, 1.005, 1.006), s1);

        Assert.Equal(6, (await GetMission(userId)).CurrentProgress);

        // Walk B (session s2): a separate 4-cell walk. Progress must STAY 6 = max(6, 4), not 6+4=10.
        var s2 = Guid.NewGuid();
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userId, null, Batch(2.001, 2.002, 2.003, 2.004), s2);

        var mission = await GetMission(userId);
        Assert.Equal(6, mission.CurrentProgress);       // pre-fix this was 10
        Assert.False(mission.IsCompleted);              // pre-fix the 8-target wrongly completed
    }

    [Fact]
    public async Task A_single_walk_reaching_the_target_completes_the_mission()
    {
        var userId = Guid.NewGuid();
        await SeedUser(userId);
        await SeedCaptureInOneWalkMission(userId, target: 8);

        // One walk capturing 9 cells across two batches (5 + 4) crosses the 8 target.
        var s1 = Guid.NewGuid();
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.001, 1.002, 1.003, 1.004, 1.005), s1);
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.006, 1.007, 1.008, 1.009), s1);

        var mission = await GetMission(userId);
        Assert.True(mission.IsCompleted);
        Assert.Equal(mission.TargetValue, mission.CurrentProgress); // clamped to target on completion
    }
}
