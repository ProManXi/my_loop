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
/// Integration test against a real PostgreSQL (spun up in-process via Testcontainers)
/// proving the ownership-race fix: two users closing a loop over the SAME hex at the
/// same time must converge to exactly one owner — no lost updates, no duplicate rows,
/// no crash. This is the scenario that motivated PR-2.
/// </summary>
public class ClaimConcurrencyTests : IAsyncLifetime
{
    private const long TargetCell = 123_456_789L;

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

    // A fresh service + DbContext per "request", exactly like two concurrent HTTP requests.
    private TerritoryService NewService(AppDbContext db)
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
    public async Task Two_concurrent_claims_on_the_same_hex_yield_exactly_one_owner()
    {
        var userA = Guid.NewGuid();
        var userB = Guid.NewGuid();
        await using (var seed = NewDb())
        {
            seed.Users.AddRange(
                new User { Id = userA, FirebaseUid = "uidA", DisplayName = "A", Color = "#111111" },
                new User { Id = userB, FirebaseUid = "uidB", DisplayName = "B", Color = "#222222" });
            await seed.SaveChangesAsync();
        }

        // 10+ points forming a closed loop (hex grid is mocked, so coordinates are nominal).
        double[][] path =
        [
            [12.900, 77.500], [12.901, 77.500], [12.901, 77.501], [12.900, 77.501],
            [12.900, 77.5005], [12.9005, 77.500], [12.9005, 77.501], [12.901, 77.5005],
            [12.9008, 77.5008], [12.900, 77.500],
        ];

        await using var dbA = NewDb();
        await using var dbB = NewDb();
        var taskA = NewService(dbA).ProcessClaim(userA, path, Guid.NewGuid());
        var taskB = NewService(dbB).ProcessClaim(userB, path, Guid.NewGuid());
        await Task.WhenAll(taskA, taskB);

        // Invariant: exactly one row for the contested cell, owned by one of the two users.
        await using var check = NewDb();
        var owners = await check.TerritoryCells
            .Where(c => c.CellId == TargetCell)
            .Select(c => c.OwnerId)
            .ToListAsync();

        Assert.Single(owners);
        Assert.True(owners[0] == userA || owners[0] == userB);

        // Neither request errored out — both returned a result (one claimed, the other
        // found the cell already owned / on cooldown and no-opped).
        Assert.True((await taskA).Success);
        Assert.True((await taskB).Success);
    }
}
