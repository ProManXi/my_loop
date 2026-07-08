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
/// Regression tests for issue #87 (S2): the daily claim cap (<see cref="GameConstants.MaxClaimsPerDay"/>)
/// was enforced only on the loop path (<c>ProcessClaim</c>), not on the live batch-step path that does
/// virtually all real capturing — so the per-day cap was effectively unenforced.
///
/// The cap counts DISTINCT walks/day (one walk = one Claim, #56), excluding the current session's own
/// Claim, so multiple batches of the SAME walk are not counted as separate claims.
/// </summary>
public class BatchStepDailyCapTests : IAsyncLifetime
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

    // Maps a GPS point to a deterministic H3 cell (cellId = round(lat * 1000)), mirroring
    // WalkSessionClaimTests so a batch's captured cells are predictable.
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
        var missions = new Mock<IMissionService> { DefaultValue = DefaultValue.Empty };
        missions.Setup(m => m.AwardXp(It.IsAny<Guid>(), It.IsAny<int>(), It.IsAny<string>()))
            .ReturnsAsync(new XpGainResult { TotalXp = 0, Level = 1, LeveledUp = false });
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };
        achievements.Setup(a => a.CheckAndUnlock(It.IsAny<Guid>()))
            .ReturnsAsync(new List<AchievementUnlock>());

        return new TerritoryService(
            db, hex.Object, geo.Object, notifier.Object, Mock.Of<IPathValidationService>(),
            push.Object, new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, NullLogger<TerritoryService>.Instance);
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
        seed.Users.Add(new User
        {
            Id = userId,
            FirebaseUid = $"uid-{userId}",
            DisplayName = "U",
            Color = "#111111",
        });
        await seed.SaveChangesAsync();
    }

    /// <summary>Seeds <paramref name="count"/> distinct completed walks (one Claim each) dated today.</summary>
    private async Task SeedClaimsToday(Guid userId, int count)
    {
        await using var seed = NewDb();
        for (var i = 0; i < count; i++)
        {
            seed.Claims.Add(new Claim
            {
                Id = Guid.NewGuid(),
                UserId = userId,
                CellCount = 1,
                AreaM2 = GameConstants.CellAreaSquareMeters,
                CreatedAt = DateTime.UtcNow, // today
            });
        }
        await seed.SaveChangesAsync();
    }

    [Fact]
    public async Task Batch_step_beyond_the_daily_cap_is_rejected_and_writes_nothing()
    {
        var userId = Guid.NewGuid();
        await SeedUser(userId);
        // Already at the cap for distinct walks today.
        await SeedClaimsToday(userId, GameConstants.MaxClaimsPerDay);

        BatchStepClaimResponse response;
        await using (var db = NewDb())
            response = await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.001), Guid.NewGuid());

        // The batch is rejected with a clear reason the controller surfaces as a 4xx.
        Assert.NotNull(response.RejectionReason);
        Assert.Contains("Daily limit", response.RejectionReason);
        Assert.Empty(response.Results);

        // Nothing was written: no 21st Claim row, no territory cell captured.
        await using var check = NewDb();
        Assert.Equal(GameConstants.MaxClaimsPerDay, await check.Claims.CountAsync(c => c.UserId == userId));
        Assert.Equal(0, await check.TerritoryCells.CountAsync(t => t.OwnerId == userId));
    }

    [Fact]
    public async Task Multiple_batches_of_one_walk_are_not_counted_as_separate_claims()
    {
        var userId = Guid.NewGuid();
        await SeedUser(userId);
        // One short of the cap: exactly one more distinct walk is allowed today.
        await SeedClaimsToday(userId, GameConstants.MaxClaimsPerDay - 1);

        var walk = Guid.NewGuid();

        // Batch 1 of the last allowed walk succeeds and creates its Claim (now at the cap).
        await using (var db = NewDb())
        {
            var r1 = await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.001), walk);
            Assert.Null(r1.RejectionReason);
        }

        // Batch 2 of the SAME walk still succeeds — the walk's own Claim is excluded from the
        // count, so it is not treated as a 21st distinct walk.
        await using (var db = NewDb())
        {
            var r2 = await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.002), walk);
            Assert.Null(r2.RejectionReason);
        }

        // A DIFFERENT new walk is now over the cap (the seeded walks + this one) and is rejected.
        await using (var db = NewDb())
        {
            var r3 = await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.003), Guid.NewGuid());
            Assert.NotNull(r3.RejectionReason);
            Assert.Contains("Daily limit", r3.RejectionReason);
        }

        // The one allowed walk is a single Claim spanning both its batches (2 cells).
        await using var check = NewDb();
        var sessionClaim = await check.Claims.SingleAsync(c => c.Id == walk);
        Assert.Equal(2, sessionClaim.CellCount);
    }
}
