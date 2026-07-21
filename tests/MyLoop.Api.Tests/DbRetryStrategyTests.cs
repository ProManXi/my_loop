using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
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
/// Regression guard for the Neon resilience change (#62): the API enables
/// <c>EnableRetryOnFailure</c>, which installs a retrying execution strategy. Npgsql throws
/// <see cref="InvalidOperationException"/> ("does not support user-initiated transactions")
/// <em>eagerly</em> — on the first <c>BeginTransactionAsync</c> outside an execution strategy,
/// regardless of whether a failure occurs. These tests build a context with retry enabled and
/// exercise every explicit-transaction code path; before each path was wrapped in
/// <c>Database.CreateExecutionStrategy().ExecuteAsync(...)</c> they threw here.
/// </summary>
public class DbRetryStrategyTests : IAsyncLifetime
{
    private const long TargetCell = 987_654_321L;

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

    // Mirrors the production wiring in AddMyLoopDatabase: retry enabled, so the retrying
    // execution strategy is active for every transaction these tests touch.
    private AppDbContext NewDb() =>
        new(new DbContextOptionsBuilder<AppDbContext>()
            .UseNpgsql(_conn, o => o.EnableRetryOnFailure(
                maxRetryCount: InfrastructureDefaults.DbMaxRetryCount,
                maxRetryDelay: TimeSpan.FromSeconds(InfrastructureDefaults.DbMaxRetryDelaySeconds),
                errorCodesToAdd: null))
            .Options);

    private TerritoryService NewTerritoryService(AppDbContext db)
    {
        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.ComputeCapturedCells(It.IsAny<double[][]>()))
            .Returns(() => new List<HexCell> { new() { CellId = TargetCell, Boundary = [[12.9, 77.5]] } });
        hex.Setup(h => h.HasClosedLoop(It.IsAny<double[][]>())).Returns(true);
        hex.Setup(h => h.CalculateArea(It.IsAny<int>())).Returns(100.0);
        hex.Setup(h => h.GetCellCenter(It.IsAny<long>())).Returns(new GeoCoordinate { Lat = 12.9, Lng = 77.5 });
        hex.Setup(h => h.GetParentCellId(It.IsAny<long>())).Returns(1L);
        hex.Setup(h => h.GetNeighborhoodId(It.IsAny<long>())).Returns(2L);

        var geo = new Mock<IGeoService>();
        geo.Setup(g => g.CalculatePathDistance(It.IsAny<double[][]>())).Returns(250.0);

        var pathValidator = new Mock<IPathValidationService>(); // Validate() -> null (allowed)
        var notifier = new Mock<ITerritoryNotifier> { DefaultValue = DefaultValue.Empty };
        var push = new Mock<IPushNotificationService> { DefaultValue = DefaultValue.Empty };
        var missions = new Mock<IMissionService> { DefaultValue = DefaultValue.Empty };
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };

        return new TerritoryService(
            db, hex.Object, geo.Object, notifier.Object, pathValidator.Object,
            push.Object, new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, Mock.Of<IServiceScopeFactory>(), NullLogger<TerritoryService>.Instance);
    }

    [Fact]
    public async Task ProcessClaim_runs_its_serializable_transaction_under_a_retrying_strategy()
    {
        var userId = Guid.NewGuid();
        await using (var seed = NewDb())
        {
            seed.Users.Add(new User { Id = userId, FirebaseUid = "uid", DisplayName = "A", Color = "#111111" });
            await seed.SaveChangesAsync();
        }

        double[][] path =
        [
            [12.900, 77.500], [12.901, 77.500], [12.901, 77.501], [12.900, 77.501],
            [12.900, 77.5005], [12.9005, 77.500], [12.9005, 77.501], [12.901, 77.5005],
            [12.9008, 77.5008], [12.900, 77.500],
        ];

        await using var db = NewDb();
        // Before the execution-strategy wrap this line threw InvalidOperationException.
        var result = await NewTerritoryService(db).ProcessClaim(userId, path, Guid.Empty);

        Assert.True(result.Success);
        await using var check = NewDb();
        Assert.Equal(userId, (await check.TerritoryCells.SingleAsync(c => c.CellId == TargetCell)).OwnerId);
        // Exactly one Claim row — guards against the post-commit side effects (now run outside the
        // execution strategy) ever re-running a committed claim and inserting a duplicate.
        Assert.Equal(1, await check.Claims.CountAsync());
    }

    [Fact]
    public async Task RefreshLeaderboard_runs_its_transaction_under_a_retrying_strategy()
    {
        var userId = Guid.NewGuid();
        var claimId = Guid.NewGuid();
        await using (var seed = NewDb())
        {
            seed.Users.Add(new User { Id = userId, FirebaseUid = "uidL", DisplayName = "L", Color = "#222222" });
            // TerritoryCell.ClaimId is a required FK to Claims, so seed the owning claim first.
            seed.Claims.Add(new Claim { Id = claimId, UserId = userId, CellCount = 1, AreaM2 = 100.0 });
            seed.TerritoryCells.Add(new TerritoryCell
            {
                CellId = TargetCell, OwnerId = userId, ClaimId = claimId, CenterLat = 12.9, CenterLng = 77.5,
                ClaimedAt = DateTime.UtcNow, LastRefreshedAt = DateTime.UtcNow,
            });
            await seed.SaveChangesAsync();
        }

        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.CalculateArea(It.IsAny<int>())).Returns(100.0);

        await using var db = NewDb();
        // Before the execution-strategy wrap this line threw InvalidOperationException.
        var count = await new LeaderboardService(db, hex.Object).RefreshLeaderboard();

        Assert.Equal(1, count);
        await using var check = NewDb();
        var entry = await check.LeaderboardEntries.SingleAsync();
        Assert.Equal(userId, entry.UserId);
        Assert.Equal(1, entry.Rank);
    }
}
