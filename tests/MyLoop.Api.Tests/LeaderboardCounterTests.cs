using Microsoft.EntityFrameworkCore;
using Moq;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Regression tests for issue #83: UpdateAchievementCounters incremented the
/// top-N finish counters on every RefreshLeaderboard() call. The refresh runs
/// hourly AND on-demand after each claim, so a rank-1 player collected ~24
/// "top-3 finishes" per day. Counters must increment at most once per calendar
/// day per user (guarded by whether the user already had a LeaderboardEntry
/// for today when the refresh started).
/// </summary>
public class LeaderboardCounterTests : IAsyncLifetime
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

    private LeaderboardService NewService(AppDbContext db)
    {
        var hex = new Mock<IHexGridService>();
        hex.Setup(h => h.CalculateArea(It.IsAny<int>())).Returns<int>(c => c * 2_150.0);
        return new LeaderboardService(db, hex.Object);
    }

    /// <summary>Seeds a user owning <paramref name="cellCount"/> cells (distinct ids from <paramref name="firstCellId"/>).</summary>
    private async Task<Guid> SeedUserWithCells(int cellCount, long firstCellId)
    {
        var userId = Guid.NewGuid();
        var claimId = Guid.NewGuid();
        await using var seed = NewDb();
        seed.Users.Add(new User { Id = userId, FirebaseUid = $"uid-{userId}", DisplayName = "U", Color = "#111111" });
        seed.Claims.Add(new Claim { Id = claimId, UserId = userId, CellCount = cellCount, AreaM2 = 0 });
        for (var i = 0; i < cellCount; i++)
        {
            seed.TerritoryCells.Add(new TerritoryCell
            {
                CellId = firstCellId + i, OwnerId = userId, ClaimId = claimId,
                CenterLat = 12.9, CenterLng = 77.5,
                ClaimedAt = DateTime.UtcNow, LastRefreshedAt = DateTime.UtcNow,
            });
        }
        await seed.SaveChangesAsync();
        return userId;
    }

    private async Task<User> GetUser(Guid id)
    {
        await using var db = NewDb();
        return await db.Users.SingleAsync(u => u.Id == id);
    }

    [Fact]
    public async Task Two_refreshes_on_the_same_day_do_not_double_increment_finish_counters()
    {
        var userId = await SeedUserWithCells(3, 1000L);

        await using (var db1 = NewDb()) await NewService(db1).RefreshLeaderboard();
        await using (var db2 = NewDb()) await NewService(db2).RefreshLeaderboard();

        var user = await GetUser(userId);
        Assert.Equal(1, user.TopThreeFinishes);
        Assert.Equal(1, user.TopTenFinishes);
        Assert.Equal(1, user.TopHundredFinishes);
        Assert.Equal(1, user.TopThousandFinishes);
    }

    [Fact]
    public async Task Rank_four_user_gets_top10_but_not_top3_credit()
    {
        // Distinct cell counts force a deterministic ranking: 5,4,3,2 cells → ranks 1-4.
        var rank1 = await SeedUserWithCells(5, 2000L);
        var rank2 = await SeedUserWithCells(4, 3000L);
        var rank3 = await SeedUserWithCells(3, 4000L);
        var rank4 = await SeedUserWithCells(2, 5000L);

        await using (var db = NewDb()) await NewService(db).RefreshLeaderboard();

        var first = await GetUser(rank1);
        Assert.Equal(1, first.TopThreeFinishes);
        Assert.Equal(1, first.TopTenFinishes);

        var fourth = await GetUser(rank4);
        Assert.Equal(0, fourth.TopThreeFinishes);
        Assert.Equal(1, fourth.TopTenFinishes);
        Assert.Equal(1, fourth.TopHundredFinishes);
        Assert.Equal(1, fourth.TopThousandFinishes);

        _ = (rank2, rank3); // seeded to pad the ranking; per-user assertions not needed
    }

    [Fact]
    public async Task User_first_appearing_on_second_refresh_of_the_day_is_still_counted_once()
    {
        var early = await SeedUserWithCells(3, 6000L);
        await using (var db1 = NewDb()) await NewService(db1).RefreshLeaderboard();

        var late = await SeedUserWithCells(2, 7000L); // first claim lands mid-day
        await using (var db2 = NewDb()) await NewService(db2).RefreshLeaderboard();
        await using (var db3 = NewDb()) await NewService(db3).RefreshLeaderboard();

        var lateUser = await GetUser(late);
        Assert.Equal(1, lateUser.TopThreeFinishes);

        var earlyUser = await GetUser(early);
        Assert.Equal(1, earlyUser.TopThreeFinishes);
    }
}
