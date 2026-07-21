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
/// Regression test for issue #54: a walk-and-loop journey claims hexes live via the
/// batch-step path (which accumulates the full GPS distance) and THEN submits the loop
/// claim to fill the interior. The loop claim used to add the whole path distance AGAIN
/// (DistanceKm stat + WalkDistance mission), so distance was counted ~2x.
///
/// This test proves the loop claim no longer touches DistanceKm — the live batch-step
/// path is the single source of truth — while still claiming the interior hexes.
/// </summary>
public class DistanceAccountingTests : IAsyncLifetime
{
    private const long TargetCell = 555_000_111L;

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

    private static TerritoryService NewService(AppDbContext db)
    {
        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.ComputeCapturedCells(It.IsAny<double[][]>()))
            .Returns(() => new List<HexCell> { new() { CellId = TargetCell, Boundary = [[12.9, 77.5]] } });
        hex.Setup(h => h.HasClosedLoop(It.IsAny<double[][]>())).Returns(true);
        hex.Setup(h => h.CalculateArea(It.IsAny<int>())).Returns(2_150.0);
        hex.Setup(h => h.GetCellCenter(It.IsAny<long>())).Returns(new GeoCoordinate { Lat = 12.9, Lng = 77.5 });
        hex.Setup(h => h.GetParentCellId(It.IsAny<long>())).Returns(1L);
        hex.Setup(h => h.GetNeighborhoodId(It.IsAny<long>())).Returns(2L);

        var geo = new Mock<IGeoService>();
        // 250 m walk: > MinWalkDistanceMeters (200) so the claim is accepted, and a clear
        // non-zero distance the loop claim must NOT add to DistanceKm.
        geo.Setup(g => g.CalculatePathDistance(It.IsAny<double[][]>())).Returns(250.0);

        var notifier = new Mock<ITerritoryNotifier> { DefaultValue = DefaultValue.Empty };
        var push = new Mock<IPushNotificationService> { DefaultValue = DefaultValue.Empty };
        var missions = new Mock<IMissionService> { DefaultValue = DefaultValue.Empty };
        missions.Setup(m => m.AwardXp(It.IsAny<Guid>(), It.IsAny<int>(), It.IsAny<string>()))
            .ReturnsAsync(new XpGainResult { TotalXp = 0, Level = 1, LeveledUp = false });
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };

        return new TerritoryService(
            db, hex.Object, geo.Object, notifier.Object, Mock.Of<IPathValidationService>(),
            push.Object, new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, Mock.Of<IServiceScopeFactory>(), NullLogger<TerritoryService>.Instance);
    }

    [Fact]
    public async Task Loop_claim_does_not_add_distance_already_counted_by_batch_step()
    {
        var userId = Guid.NewGuid();
        await using (var seed = NewDb())
        {
            // Simulate the state AFTER a live walk: the batch-step path already recorded the
            // walk's distance (0.25 km here). No home set → decay short-circuits.
            seed.Users.Add(new User
            {
                Id = userId, FirebaseUid = "uid", DisplayName = "A", Color = "#111111",
                DistanceKm = 0.25, HexCount = 0,
            });
            await seed.SaveChangesAsync();
        }

        // 10 points (>= MinGpsPointsPerClaim) forming a closed loop; geometry is mocked.
        double[][] path =
        [
            [12.900, 77.500], [12.901, 77.500], [12.901, 77.501], [12.900, 77.501],
            [12.900, 77.5005], [12.9005, 77.500], [12.9005, 77.501], [12.901, 77.5005],
            [12.9008, 77.5008], [12.900, 77.500],
        ];

        await using var db = NewDb();
        var result = await NewService(db).ProcessClaim(userId, path, Guid.NewGuid());
        Assert.True(result.Success);

        await using var check = NewDb();
        var user = await check.Users.SingleAsync(u => u.Id == userId);

        // The loop claim must NOT re-add the 0.25 km the batch-step path already counted.
        Assert.Equal(0.25, user.DistanceKm, precision: 6);
        // ...but it still claims the interior hex (proving the claim ran, distance aside).
        Assert.Equal(1, user.HexCount);
    }
}
