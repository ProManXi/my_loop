using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using MyLoop.Api.Controllers;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Models;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #121 (ML-ERR-024): <c>GET /api/users/{id}/game-state</c> resolved
/// <c>IMissionService</c>/<c>IAchievementService</c>/<c>ITerritoryService</c> via
/// <c>HttpContext.RequestServices.GetRequiredService</c> instead of constructor injection —
/// invisible dependencies that also NRE the moment the controller isn't running inside the
/// full ASP.NET pipeline (e.g. here, a plain unit test with no <c>ControllerContext</c> set).
/// Rank was also computed by loading every same-city user id into memory and calling
/// <c>List.IndexOf</c> — an O(city population) scan on an endpoint hit at every login and
/// walk-end. Both are now constructor-injected services and a single scoped COUNT query.
/// </summary>
public class GameStateRankTests : IAsyncLifetime
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

    /// <summary>
    /// Builds the controller exactly as DI would — constructor-injected throughout, no
    /// <c>ControllerContext</c>/<c>HttpContext</c> attached. If <c>GetGameState</c> ever went back
    /// to resolving services via <c>HttpContext.RequestServices</c>, this would NRE immediately.
    /// </summary>
    private UsersController BuildController(AppDbContext db, Guid callerId)
    {
        var currentUser = new Mock<ICurrentUser>();
        currentUser.Setup(c => c.TryGetUserIdAsync()).ReturnsAsync(callerId);

        var missions = new Mock<IMissionService>();
        missions.Setup(m => m.GetTodaysMissions(It.IsAny<Guid>(), It.IsAny<DateOnly?>()))
            .ReturnsAsync([]);
        var achievements = new Mock<IAchievementService>();
        achievements.Setup(a => a.GetAllForUser(It.IsAny<Guid>())).ReturnsAsync([]);
        var territory = new Mock<ITerritoryService>();
        territory.Setup(t => t.GetExplorationStats(It.IsAny<Guid>(), It.IsAny<double>(), It.IsAny<double>()))
            .ReturnsAsync([]);

        return new UsersController(
            Mock.Of<IUserService>(), Mock.Of<IValidationService>(), Mock.Of<IPushNotificationService>(),
            geocoding: null!, db, currentUser.Object,
            missions.Object, achievements.Object, territory.Object,
            NullLogger<UsersController>.Instance);
    }

    private async Task<Guid> SeedUser(string city, int hexCount)
    {
        var userId = Guid.NewGuid();
        await using var seed = NewDb();
        seed.Users.Add(new User
        {
            Id = userId, FirebaseUid = $"uid-{userId}", DisplayName = "P", Color = "#123456",
            City = city, HexCount = hexCount,
        });
        await seed.SaveChangesAsync();
        return userId;
    }

    private static int RankOf(IActionResult result)
    {
        var ok = Assert.IsType<OkObjectResult>(result);
        var rankProp = ok.Value!.GetType().GetProperty("Rank")!;
        return (int)rankProp.GetValue(ok.Value)!;
    }

    [Fact]
    public async Task Tied_users_share_the_same_rank_and_next_distinct_score_skips_past_the_tie()
    {
        var leaderA = await SeedUser("Testville", hexCount: 10);
        var leaderB = await SeedUser("Testville", hexCount: 10); // ties leaderA
        var thirdPlace = await SeedUser("Testville", hexCount: 5);

        await using var dbA = NewDb();
        var rankA = RankOf(await BuildController(dbA, leaderA).GetGameState(leaderA));
        await using var dbB = NewDb();
        var rankB = RankOf(await BuildController(dbB, leaderB).GetGameState(leaderB));
        await using var dbC = NewDb();
        var rankThird = RankOf(await BuildController(dbC, thirdPlace).GetGameState(thirdPlace));

        // Nobody has strictly more hexes than either tied leader -> both are rank 1.
        Assert.Equal(1, rankA);
        Assert.Equal(1, rankB);
        // Two users (both tied leaders) have strictly more hexes than third place -> rank 3,
        // not 2 -- ranks are not renumbered densely across a tie.
        Assert.Equal(3, rankThird);
    }

    [Fact]
    public async Task Rank_only_counts_users_in_the_same_city()
    {
        var localLeader = await SeedUser("Testville", hexCount: 100);
        var caller = await SeedUser("Testville", hexCount: 1);
        await SeedUser("OtherCity", hexCount: 1000); // would dominate rank if city scoping broke

        await using var db = NewDb();
        var rank = RankOf(await BuildController(db, caller).GetGameState(caller));

        // Only the one same-city user (100 > 1) counts; the 1000-hex OtherCity user does not.
        Assert.Equal(2, rank);
    }
}
