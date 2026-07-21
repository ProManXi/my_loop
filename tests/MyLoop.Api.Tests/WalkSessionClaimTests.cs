using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Models;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #56: a single continuous walk used to fragment into one Claim
/// row per drained batch (plus a separate loop-claim row), so Walk History showed one walk as
/// many entries. The fix makes the client stamp every batch-step and the final loop claim with
/// one walkSessionId; the server upserts a single Claim keyed on it — one walk = one Claim.
///
/// CellCount accumulates the NET cells the walk added (transfer count, which excludes cells the
/// user already owns), and AreaM2 is derived from the canonical cell area, never the legacy 4234.
/// </summary>
public class WalkSessionClaimTests : IAsyncLifetime
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

    // Maps a GPS point to a deterministic H3 cell so tests can choose which cells a batch hits:
    // cellId = round(lat * 1000). Distinct lats → distinct cells.
    private static long CellOf(double lat) => (long)Math.Round(lat * 1000);

    private static TerritoryService NewService(AppDbContext db, IReadOnlyList<long>? loopCells = null)
    {
        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.GetCellAtPoint(It.IsAny<double>(), It.IsAny<double>()))
            .Returns<double, double>((lat, lng) => new HexCell { CellId = CellOf(lat), Boundary = [[lat, lng]] });
        hex.Setup(h => h.ComputeCapturedCells(It.IsAny<double[][]>()))
            .Returns(() => (loopCells ?? [])
                .Select(id => new HexCell { CellId = id, Boundary = [[12.9, 77.5]] })
                .ToList());
        hex.Setup(h => h.HasClosedLoop(It.IsAny<double[][]>())).Returns(true);
        hex.Setup(h => h.CalculateArea(It.IsAny<int>())).Returns<int>(c => c * 2_150.0);
        hex.Setup(h => h.GetCellCenter(It.IsAny<long>())).Returns(new GeoCoordinate { Lat = 12.9, Lng = 77.5 });
        hex.Setup(h => h.GetParentCellId(It.IsAny<long>())).Returns(1L);
        hex.Setup(h => h.GetNeighborhoodId(It.IsAny<long>())).Returns(2L);

        var geo = new Mock<IGeoService>();
        geo.Setup(g => g.CalculatePathDistance(It.IsAny<double[][]>())).Returns(250.0);

        var notifier = new Mock<ITerritoryNotifier> { DefaultValue = DefaultValue.Empty };
        var push = new Mock<IPushNotificationService> { DefaultValue = DefaultValue.Empty };
        var missions = new Mock<IMissionService> { DefaultValue = DefaultValue.Empty };
        missions.Setup(m => m.AwardXp(It.IsAny<Guid>(), It.IsAny<int>(), It.IsAny<string>()))
            .ReturnsAsync(new XpGainResult { TotalXp = 0, Level = 1, LeveledUp = false });
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };
        // CheckAndUnlock feeds a non-null-guarded .Select in the response builder; the real
        // service never returns null, so the mock must return an (empty) list, not default.
        achievements.Setup(a => a.CheckAndUnlock(It.IsAny<Guid>()))
            .ReturnsAsync(new List<AchievementUnlock>());

        return new TerritoryService(
            db, hex.Object, geo.Object, notifier.Object, Mock.Of<IPathValidationService>(),
            push.Object, new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, Mock.Of<IServiceScopeFactory>(), NullLogger<TerritoryService>.Instance);
    }

    private static List<BatchStepPoint> Batch(params double[] lats) =>
        lats.Select((lat, i) => new BatchStepPoint
        {
            ClientId = $"{lat}_{i}",
            Lat = lat,
            Lng = 77.5,
            CapturedAt = DateTime.UtcNow,
        }).ToList();

    private async Task SeedUser(Guid userId, string suffix = "")
    {
        await using var seed = NewDb();
        seed.Users.Add(new User
        {
            Id = userId,
            FirebaseUid = $"uid{suffix}{userId}",
            DisplayName = $"U{suffix}",
            Color = "#111111",
        });
        await seed.SaveChangesAsync();
    }

    [Fact]
    public async Task Multiple_batches_sharing_a_session_collapse_into_one_claim()
    {
        var userId = Guid.NewGuid();
        var session = Guid.NewGuid();
        await SeedUser(userId);

        // Two batches of the same walk, four distinct new cells in total.
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.001, 1.002), session);
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.003, 1.004), session);

        await using var check = NewDb();
        var claims = await check.Claims.Where(c => c.UserId == userId).ToListAsync();

        Assert.Single(claims);
        Assert.Equal(session, claims[0].Id);
        // Net cells across both batches = 4; area derived from the canonical constant (not 4234).
        Assert.Equal(4, claims[0].CellCount);
        Assert.Equal(4 * 2_150.0, claims[0].AreaM2);
        // The walk's geometry accumulates across batches — the Claim keeps both batches' points
        // (2 + 2), not just the first batch's, so anti-cheat forensics see the whole path (#56).
        var polygon = claims[0].GetPolygon();
        Assert.Equal(4, polygon.Length);
        Assert.Contains(polygon, p => Math.Abs(p[0] - 1.003) < 1e-9); // a point from the second batch
    }

    [Fact]
    public async Task Loop_claim_merges_into_the_walk_session_claim_not_a_new_row()
    {
        var userId = Guid.NewGuid();
        var session = Guid.NewGuid();
        await SeedUser(userId);

        // Live walk claims the trail cells 1001 and 1002 via batch-step.
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.001, 1.002), session);

        // On stop, the loop encloses the trail (1001, 1002 — already owned) plus interior 1003.
        long[] loopCells = [1001, 1002, 1003];
        double[][] path =
        [
            [12.900, 77.500], [12.901, 77.500], [12.901, 77.501], [12.900, 77.501],
            [12.900, 77.5005], [12.9005, 77.500], [12.9005, 77.501], [12.901, 77.5005],
            [12.9008, 77.5008], [12.900, 77.500],
        ];
        await using (var db = NewDb())
        {
            var result = await NewService(db, loopCells).ProcessClaim(userId, path, session);
            Assert.True(result.Success);
            // The response still reports THIS loop's enclosed cells (contract unchanged, #55).
            Assert.Equal(loopCells.Length, result.Data!.CellCount);
            Assert.Equal(1, result.Data.NewlyClaimedCount); // only 1003 is new
        }

        await using var check = NewDb();
        var claims = await check.Claims.Where(c => c.UserId == userId).ToListAsync();

        Assert.Single(claims);            // loop claim merged — no extra row
        Assert.Equal(session, claims[0].Id);
        Assert.Equal(3, claims[0].CellCount); // 2 trail (batch) + 1 interior (loop), disjoint
        Assert.Equal(3 * 2_150.0, claims[0].AreaM2);
    }

    [Fact]
    public async Task Empty_session_keeps_legacy_one_claim_per_batch_behaviour()
    {
        var userId = Guid.NewGuid();
        await SeedUser(userId);

        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.001, 1.002), Guid.Empty);
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userId, null, Batch(1.003, 1.004), Guid.Empty);

        await using var check = NewDb();
        var claims = await check.Claims.Where(c => c.UserId == userId).ToListAsync();

        // No session id → each batch is a standalone Claim, exactly as before #56.
        Assert.Equal(2, claims.Count);
    }

    [Fact]
    public async Task A_supplied_session_id_owned_by_another_user_is_never_mutated()
    {
        var userA = Guid.NewGuid();
        var userB = Guid.NewGuid();
        var session = Guid.NewGuid();
        await SeedUser(userA, "A");
        await SeedUser(userB, "B");

        // User A starts a walk under `session` and claims two cells.
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userA, null, Batch(1.001, 1.002), session);

        // User B maliciously submits the SAME session id (e.g. learned from public cell history),
        // claiming different cells. It must not touch A's claim — B gets a fresh claim of its own.
        await using (var db = NewDb())
            await NewService(db).ProcessBatchStepClaim(userB, null, Batch(2.001, 2.002), session);

        await using var check = NewDb();
        var aClaim = await check.Claims.SingleAsync(c => c.Id == session);
        Assert.Equal(userA, aClaim.UserId);
        Assert.Equal(2, aClaim.CellCount); // untouched by B

        var bClaims = await check.Claims.Where(c => c.UserId == userB).ToListAsync();
        Assert.Single(bClaims);
        Assert.NotEqual(session, bClaims[0].Id); // B forced onto a fresh id
        Assert.Equal(2, bClaims[0].CellCount);
    }
}
