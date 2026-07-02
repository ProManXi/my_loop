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
/// Regression tests for issue #85: CellCooldownHours shipped as a ~1-minute testing literal
/// (0.0167), which effectively removed steal-back protection in production and allowed
/// rapid ping-pong ownership flipping between two players.
/// </summary>
public class CellCooldownConstantTests
{
    [Fact]
    public void CellCooldownHours_is_a_production_value_not_a_testing_literal()
    {
        // Sub-hour cooldowns are testing artifacts — a production steal-back window
        // must be at least an hour for cooldown protection to mean anything.
        Assert.True(GameConstants.CellCooldownHours >= 1.0,
            $"CellCooldownHours = {GameConstants.CellCooldownHours} looks like a testing value");
    }
}

public class CellCooldownTests : IAsyncLifetime
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

    private const long SharedCellId = 501L;

    private static TerritoryService NewService(AppDbContext db)
    {
        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.GetCellAtPoint(It.IsAny<double>(), It.IsAny<double>()))
            .Returns(new HexCell { CellId = SharedCellId, Boundary = [[12.9, 77.5]] });
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
        achievements.Setup(a => a.CheckAndUnlock(It.IsAny<Guid>()))
            .ReturnsAsync(new List<AchievementUnlock>());

        return new TerritoryService(
            db, hex.Object, geo.Object, notifier.Object, Mock.Of<IPathValidationService>(),
            push.Object, new GeocodingService(new HttpClient(), NullLogger<GeocodingService>.Instance),
            missions.Object, achievements.Object, NullLogger<TerritoryService>.Instance);
    }

    private static List<BatchStepPoint> SinglePoint() =>
        [new BatchStepPoint { ClientId = Guid.NewGuid().ToString(), Lat = 12.9, Lng = 77.5, CapturedAt = DateTime.UtcNow }];

    private async Task<(Guid UserA, Guid UserB)> SeedTwoUsers()
    {
        var userA = Guid.NewGuid();
        var userB = Guid.NewGuid();
        await using var seed = NewDb();
        seed.Users.Add(new User { Id = userA, FirebaseUid = "uid-a", DisplayName = "A", Color = "#111111" });
        seed.Users.Add(new User { Id = userB, FirebaseUid = "uid-b", DisplayName = "B", Color = "#222222" });
        await seed.SaveChangesAsync();
        return (userA, userB);
    }

    [Fact]
    public async Task Captured_cell_is_on_cooldown_for_the_configured_duration_and_cannot_be_stolen()
    {
        var (userA, userB) = await SeedTwoUsers();

        await using (var dbA = NewDb())
        {
            var before = DateTime.UtcNow;
            var claim = await NewService(dbA).ProcessBatchStepClaim(userA, null, SinglePoint(), Guid.NewGuid());
            Assert.True(claim.Results.Single().Claimed);

            await using var check = NewDb();
            var cell = await check.TerritoryCells.SingleAsync(t => t.CellId == SharedCellId);
            var expectedExpiry = before.AddHours(GameConstants.CellCooldownHours);
            Assert.NotNull(cell.CooldownExpiresAt);
            Assert.InRange(cell.CooldownExpiresAt!.Value,
                expectedExpiry.AddMinutes(-6), expectedExpiry.AddMinutes(6));
        }

        await using var dbB = NewDb();
        var steal = await NewService(dbB).ProcessBatchStepClaim(userB, null, SinglePoint(), Guid.NewGuid());

        var result = steal.Results.Single();
        Assert.False(result.Claimed);
        Assert.Equal("cooldown", result.SkipReason);

        await using var verify = NewDb();
        var owner = await verify.TerritoryCells.SingleAsync(t => t.CellId == SharedCellId);
        Assert.Equal(userA, owner.OwnerId);
    }

    [Fact]
    public async Task Cell_is_stealable_after_cooldown_expires()
    {
        var (userA, userB) = await SeedTwoUsers();

        await using (var dbA = NewDb())
        {
            var claim = await NewService(dbA).ProcessBatchStepClaim(userA, null, SinglePoint(), Guid.NewGuid());
            Assert.True(claim.Results.Single().Claimed);
        }

        await using (var expire = NewDb())
        {
            var cell = await expire.TerritoryCells.SingleAsync(t => t.CellId == SharedCellId);
            cell.CooldownExpiresAt = DateTime.UtcNow.AddSeconds(-1);
            await expire.SaveChangesAsync();
        }

        await using var dbB = NewDb();
        var steal = await NewService(dbB).ProcessBatchStepClaim(userB, null, SinglePoint(), Guid.NewGuid());

        var result = steal.Results.Single();
        Assert.True(result.Claimed);
        Assert.True(result.WasStolen);

        await using var verify = NewDb();
        var owner = await verify.TerritoryCells.SingleAsync(t => t.CellId == SharedCellId);
        Assert.Equal(userB, owner.OwnerId);
    }
}
