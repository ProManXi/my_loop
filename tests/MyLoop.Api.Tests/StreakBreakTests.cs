using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Integration tests (real PostgreSQL via Testcontainers) for the timezone-safe streak reaper.
///
/// LastClaimDate is recorded in the player's LOCAL frame (clamped to UTC ±1 by
/// TerritoryService.ResolveStreakDate), so a streak still alive in some timezone can trail UTC by
/// up to two days. The UTC-only background reaper must therefore break only streaks older than
/// GameConstants.StreakBreakUtcGraceDays days — never one an honest local claim would still keep.
///
/// See vault bug: bug-2026-07-02-streak-break-semantics-divergence.
/// </summary>
public class StreakBreakTests : IAsyncLifetime
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

    private static User NewUser(Guid id, DateOnly? lastClaim, bool active, int streak) =>
        new()
        {
            Id = id,
            FirebaseUid = $"uid-{id}",
            DisplayName = "P",
            Color = "#111111",
            LastClaimDate = lastClaim,
            IsStreakActive = active,
            Streak = streak,
        };

    [Fact]
    public async Task Reaper_breaks_only_streaks_stale_beyond_the_timezone_grace()
    {
        var utcToday = DateOnly.FromDateTime(DateTime.UtcNow);

        // Alive in some timezone: last claim is exactly at the grace edge (UTC today − 2).
        var edgeAlive = Guid.NewGuid();
        // Dead everywhere: one day past the grace edge.
        var stale = Guid.NewGuid();
        // Never claimed but flagged active — must be broken.
        var neverClaimed = Guid.NewGuid();
        // Claimed today — clearly alive.
        var claimedToday = Guid.NewGuid();
        // Already inactive — the reaper only touches active streaks, so it must be left alone.
        var alreadyInactive = Guid.NewGuid();

        await using (var seed = NewDb())
        {
            seed.Users.AddRange(
                NewUser(edgeAlive, utcToday.AddDays(-GameConstants.StreakBreakUtcGraceDays), active: true, streak: 5),
                NewUser(stale, utcToday.AddDays(-(GameConstants.StreakBreakUtcGraceDays + 1)), active: true, streak: 5),
                NewUser(neverClaimed, null, active: true, streak: 1),
                NewUser(claimedToday, utcToday, active: true, streak: 7),
                NewUser(alreadyInactive, utcToday.AddDays(-10), active: false, streak: 0));
            await seed.SaveChangesAsync();
        }

        int broken;
        await using (var db = NewDb())
        {
            broken = await DecayCleanupService.BreakStaleStreaksAsync(
                db, GameConstants.StreakBreakUtcGraceDays, CancellationToken.None);
        }

        // Only `stale` and `neverClaimed` are broken.
        Assert.Equal(2, broken);

        await using var check = NewDb();
        var users = await check.Users.AsNoTracking().ToDictionaryAsync(u => u.Id);

        // Broken → Streak 0, inactive.
        Assert.Equal(0, users[stale].Streak);
        Assert.False(users[stale].IsStreakActive);
        Assert.Equal(0, users[neverClaimed].Streak);
        Assert.False(users[neverClaimed].IsStreakActive);

        // Survived → untouched.
        Assert.Equal(5, users[edgeAlive].Streak);
        Assert.True(users[edgeAlive].IsStreakActive);
        Assert.Equal(7, users[claimedToday].Streak);
        Assert.True(users[claimedToday].IsStreakActive);

        // Already-inactive row is not re-processed.
        Assert.Equal(0, users[alreadyInactive].Streak);
        Assert.False(users[alreadyInactive].IsStreakActive);
    }
}
