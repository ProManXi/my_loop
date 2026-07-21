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
/// Regression test for issue #55: the capture celebration adds the loop claim's count on
/// top of the hexes already claimed live during the walk. ProcessClaim used to expose
/// CellCount (every cell enclosed by the loop, including the trail hexes the user already
/// owned), so the client double-counted the trail. The fix exposes NewlyClaimedCount —
/// only the cells this claim actually assigned (interior fill + steals), excluding cells
/// the user already owned.
/// </summary>
public class ClaimNewlyClaimedCountTests : IAsyncLifetime
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

    private static TerritoryService NewService(AppDbContext db, IReadOnlyList<long> loopCells)
    {
        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.ComputeCapturedCells(It.IsAny<double[][]>()))
            .Returns(() => loopCells
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

        return new TerritoryService(
            db, hex.Object, geo.Object, notifier.Object, Mock.Of<IPathValidationService>(),
            push.Object, new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, Mock.Of<IServiceScopeFactory>(), NullLogger<TerritoryService>.Instance);
    }

    [Fact]
    public async Task Loop_claim_reports_only_newly_assigned_cells_not_already_owned_trail()
    {
        var userId = Guid.NewGuid();
        var seedClaimId = Guid.NewGuid();

        // Two of the loop's cells (201, 202) are already owned by the user — these stand in
        // for the trail hexes claimed live via batch-step during the walk. Only 203 is new.
        long[] alreadyOwned = [201L, 202L];
        const long newInteriorCell = 203L;
        long[] loopCells = [201L, 202L, newInteriorCell];

        await using (var seed = NewDb())
        {
            seed.Users.Add(new User { Id = userId, FirebaseUid = "uid", DisplayName = "A", Color = "#111111" });
            seed.Claims.Add(new Claim { Id = seedClaimId, UserId = userId, CellCount = alreadyOwned.Length, AreaM2 = 0 });
            foreach (var cellId in alreadyOwned)
            {
                seed.TerritoryCells.Add(new TerritoryCell
                {
                    CellId = cellId,
                    OwnerId = userId,
                    ClaimId = seedClaimId,
                    ClaimedAt = DateTime.UtcNow.AddMinutes(-10),
                    LastRefreshedAt = DateTime.UtcNow.AddMinutes(-10),
                    CooldownExpiresAt = null, // not on cooldown → exercises the "already mine" skip
                    CenterLat = 12.9, CenterLng = 77.5,
                    ParentCellId = 1L, NeighborhoodId = 2L,
                });
            }
            await seed.SaveChangesAsync();
        }

        double[][] path =
        [
            [12.900, 77.500], [12.901, 77.500], [12.901, 77.501], [12.900, 77.501],
            [12.900, 77.5005], [12.9005, 77.500], [12.9005, 77.501], [12.901, 77.5005],
            [12.9008, 77.5008], [12.900, 77.500],
        ];

        await using var db = NewDb();
        var result = await NewService(db, loopCells).ProcessClaim(userId, path, Guid.NewGuid());

        Assert.True(result.Success);
        // CellCount = every cell the loop encloses (trail + interior) = 3.
        Assert.Equal(loopCells.Length, result.Data!.CellCount);
        // NewlyClaimedCount = only the cell this claim actually added (203) = 1.
        // The celebration adds THIS to the live count, so the trail hexes are not double-counted.
        Assert.Equal(1, result.Data.NewlyClaimedCount);
    }
}
