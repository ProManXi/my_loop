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
/// Regression tests for issue #101 (ML-ERR-004): CalculateDecayDays used to await
/// GeocodingService.GetLocationInfo — an externally-throttled (1 req/1.1s) Nominatim HTTP
/// call — per far-from-home cell, INSIDE the serializable claim transaction while holding
/// the per-user advisory lock. A 60-cell batch abroad could hold the transaction (and the
/// app-wide geocoding throttle) for about a minute. The fix makes decay a pure
/// distance-ladder computation with no I/O, so both claim paths must never touch
/// GeocodingService regardless of how far the cell is from the user's home.
/// </summary>
public class DecayNoGeocodingTests : IAsyncLifetime
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

    /// <summary>Throws on any request — proves the claim path never dispatches an HTTP call.</summary>
    private sealed class ThrowingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
            => throw new InvalidOperationException(
                "GeocodingService must never be called from inside the claim transaction (ML-ERR-004)");
    }

    private static GeocodingService ThrowingGeocoder() =>
        new(new HttpClient(new ThrowingHandler()), NullLogger<GeocodingService>.Instance);

    // Far enough from the fixed hex center (12.9, 77.5) below to have crossed the old
    // SameCityDistanceKm (30km) fast-path and reached the geocoding branch pre-fix.
    private const double FarDistanceMeters = 1_500_000; // 1,500 km

    private TerritoryService NewService(AppDbContext db, IReadOnlyList<long>? loopCells = null)
    {
        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.GetCellAtPoint(It.IsAny<double>(), It.IsAny<double>()))
            .Returns(new HexCell { CellId = 9001L, Boundary = [[12.9, 77.5]] });
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
        geo.Setup(g => g.HaversineMeters(
                It.IsAny<double>(), It.IsAny<double>(), It.IsAny<double>(), It.IsAny<double>()))
            .Returns(FarDistanceMeters);

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
            push.Object, ThrowingGeocoder(),
            missions.Object, achievements.Object, NullLogger<TerritoryService>.Instance);
    }

    private async Task SeedUserWithFarHome(Guid userId)
    {
        await using var seed = NewDb();
        seed.Users.Add(new User
        {
            Id = userId,
            FirebaseUid = $"uid{userId}",
            DisplayName = "U",
            Color = "#111111",
            HomeLat = 40.7128,
            HomeLng = -74.0060,
        });
        await seed.SaveChangesAsync();
    }

    [Fact]
    public async Task Batch_step_claim_of_a_far_from_home_cell_never_calls_geocoding()
    {
        var userId = Guid.NewGuid();
        await SeedUserWithFarHome(userId);

        var points = new List<BatchStepPoint>
        {
            new() { ClientId = "p1", Lat = 12.9, Lng = 77.5, CapturedAt = DateTime.UtcNow },
        };

        await using var db = NewDb();
        // Throws if the claim path ever dispatches an HTTP request via GeocodingService.
        var response = await NewService(db).ProcessBatchStepClaim(userId, null, points, Guid.NewGuid());

        Assert.Null(response.RejectionReason);

        await using var check = NewDb();
        var cell = await check.TerritoryCells.SingleAsync(c => c.CellId == 9001L);
        // 1,500km falls in the (1000, 5000) km tier → DecayDaysOtherCountry.
        Assert.Equal(GameConstants.DecayDaysOtherCountry, cell.DecayDays);
    }

    [Fact]
    public async Task Loop_claim_of_far_from_home_cells_never_calls_geocoding()
    {
        var userId = Guid.NewGuid();
        await SeedUserWithFarHome(userId);

        var path = Enumerable.Range(0, 12)
            .Select(i => new[] { 12.9 + i * 0.0001, 77.5 })
            .ToArray();

        await using var db = NewDb();
        // Throws if the claim path ever dispatches an HTTP request via GeocodingService.
        var result = await NewService(db, loopCells: [9001L]).ProcessClaim(userId, path, Guid.NewGuid());

        Assert.True(result.Success);

        await using var check = NewDb();
        var cell = await check.TerritoryCells.SingleAsync(c => c.CellId == 9001L);
        Assert.Equal(GameConstants.DecayDaysOtherCountry, cell.DecayDays);
    }
}

/// <summary>
/// Acceptance criterion (b) from issue #101: the distance ladder GeocodingService's removed
/// per-cell call used to approximate must stay pinned at its documented boundaries.
/// </summary>
public class DecayDaysForDistanceLadderTests
{
    [Theory]
    [InlineData(0, GameConstants.DecayDays)]
    [InlineData(29.9, GameConstants.DecayDays)]
    [InlineData(30, GameConstants.DecayDaysOtherCity)]
    [InlineData(199.9, GameConstants.DecayDaysOtherCity)]
    [InlineData(200, GameConstants.DecayDaysOtherRegion)]
    [InlineData(999.9, GameConstants.DecayDaysOtherRegion)]
    [InlineData(1000, GameConstants.DecayDaysOtherCountry)]
    [InlineData(4999.9, GameConstants.DecayDaysOtherCountry)]
    [InlineData(5000, GameConstants.DecayDaysOtherContinent)]
    [InlineData(20000, GameConstants.DecayDaysOtherContinent)]
    public void Ladder_returns_expected_tier(double distanceKm, int expected)
    {
        Assert.Equal(expected, GameConstants.GetDecayDaysForDistance(distanceKm));
    }
}
