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
/// Regression tests for ML-ERR-021 (issue #118): a batch-step slice that claims nothing —
/// e.g. laps inside territory the user already owns — accrued DistanceKm (the profile stat)
/// but never recorded WalkDistance mission progress, because the mission block was gated on
/// totalClaimedThisBatch > 0. Two meters measuring the same walk visibly contradicted each
/// other: the profile distance grew while "Walk 1 km" stayed frozen.
/// </summary>
public class WalkDistanceMissionTests : IAsyncLifetime
{
    private const long OwnedCell = 777_000_222L;

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

    private static TerritoryService NewService(AppDbContext db, Mock<IMissionService> missions)
    {
        var hex = new Mock<IHexGridService>();
        // Every point resolves to the cell the user ALREADY owns — nothing claimable.
        hex.Setup(h => h.GetCellAtPoint(It.IsAny<double>(), It.IsAny<double>()))
            .Returns(new HexCell { CellId = OwnedCell, Boundary = [[12.9, 77.5]] });
        hex.Setup(h => h.GetCellCenter(It.IsAny<long>())).Returns(new GeoCoordinate { Lat = 12.9, Lng = 77.5 });
        hex.Setup(h => h.GetParentCellId(It.IsAny<long>())).Returns(1L);
        hex.Setup(h => h.GetNeighborhoodId(It.IsAny<long>())).Returns(2L);

        var geo = new Mock<IGeoService>();
        geo.Setup(g => g.CalculatePathDistance(It.IsAny<double[][]>())).Returns(400.0);

        var notifier = new Mock<ITerritoryNotifier> { DefaultValue = DefaultValue.Empty };
        var push = new Mock<IPushNotificationService> { DefaultValue = DefaultValue.Empty };
        var achievements = new Mock<IAchievementService> { DefaultValue = DefaultValue.Empty };

        return new TerritoryService(
            db, hex.Object, geo.Object, notifier.Object, Mock.Of<IPathValidationService>(),
            push.Object, new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, Mock.Of<IServiceScopeFactory>(), NullLogger<TerritoryService>.Instance);
    }

    private async Task<Guid> SeedUserOwningTheCell()
    {
        var userId = Guid.NewGuid();
        var claimId = Guid.NewGuid();
        await using var seed = NewDb();
        seed.Users.Add(new User { Id = userId, FirebaseUid = "uid-wd", DisplayName = "W", Color = "#444444" });
        seed.Claims.Add(new Claim { Id = claimId, UserId = userId, CellCount = 1 });
        var cell = new TerritoryCell
        {
            CellId = OwnedCell,
            OwnerId = userId,
            ClaimId = claimId,
            ClaimedAt = DateTime.UtcNow.AddDays(-1),
            LastRefreshedAt = DateTime.UtcNow.AddDays(-1),
            CenterLat = 12.9,
            CenterLng = 77.5,
            ParentCellId = 1L,
            NeighborhoodId = 2L,
        };
        cell.SetBoundary([[12.9, 77.5]]);
        seed.TerritoryCells.Add(cell);
        await seed.SaveChangesAsync();
        return userId;
    }

    private static List<BatchStepPoint> TwoPointsInOwnedTerritory() =>
    [
        new BatchStepPoint { ClientId = "p1", Lat = 12.9000, Lng = 77.5000, CapturedAt = DateTime.UtcNow.AddSeconds(-60) },
        new BatchStepPoint { ClientId = "p2", Lat = 12.9036, Lng = 77.5000, CapturedAt = DateTime.UtcNow },
    ];

    [Fact]
    public async Task Zero_claim_batch_still_records_WalkDistance_mission_progress()
    {
        var userId = await SeedUserOwningTheCell();

        var missions = new Mock<IMissionService> { DefaultValue = DefaultValue.Empty };
        missions.Setup(m => m.RecordProgress(
                userId, MissionType.WalkDistance, It.IsAny<int>(), It.IsAny<DateOnly?>()))
            .ReturnsAsync(new MissionProgressResult
            {
                Missions =
                [
                    new DailyMission
                    {
                        Id = Guid.NewGuid(), UserId = userId, Type = MissionType.WalkDistance,
                        TargetValue = 1000, CurrentProgress = 400, XpReward = 70,
                        Description = "Walk 1 kilometer",
                    },
                ],
            });

        await using var db = NewDb();
        var response = await NewService(db, missions)
            .ProcessBatchStepClaim(userId, null, TwoPointsInOwnedTerritory(), Guid.NewGuid());

        // Nothing was claimable — both points sit on the user's own cell.
        Assert.DoesNotContain(response.Results, r => r.Claimed);

        // The walked 400 m must progress the WalkDistance mission exactly like the
        // DistanceKm stat it mirrors...
        missions.Verify(m => m.RecordProgress(
            userId, MissionType.WalkDistance, 400, It.IsAny<DateOnly?>()), Times.Once);
        // ...and the response must carry the update so the client's mission card moves.
        var update = Assert.Single(response.Missions);
        Assert.Equal(nameof(MissionType.WalkDistance), update.Type);
        Assert.Equal(400, update.CurrentProgress);

        // Claim-gated missions stay untouched on a zero-claim slice.
        missions.Verify(m => m.RecordProgress(
            userId, MissionType.CaptureHexes, It.IsAny<int>(), It.IsAny<DateOnly?>()), Times.Never);

        await using var check = NewDb();
        var user = await check.Users.SingleAsync(u => u.Id == userId);
        Assert.Equal(0.4, user.DistanceKm, precision: 6);
    }
}
