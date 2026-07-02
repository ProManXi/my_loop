using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// Integration tests (real PostgreSQL via Testcontainers) proving daily missions generate and
/// progress against the player's supplied game day, not server UTC — the fix for missions resetting
/// mid-day for players far from UTC.
///
/// See vault bug: bug-2026-07-02-mission-day-uses-utc-not-player-local-day.
/// </summary>
public class MissionLocalDayTests : IAsyncLifetime
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

    private async Task<Guid> SeedUser()
    {
        var id = Guid.NewGuid();
        await using var db = NewDb();
        db.Users.Add(new User { Id = id, FirebaseUid = $"uid-{id}", DisplayName = "P", Color = "#111111" });
        await db.SaveChangesAsync();
        return id;
    }

    [Fact]
    public async Task Missions_generate_for_the_supplied_game_day_not_utc()
    {
        var userId = await SeedUser();
        // Deliberately a fixed date unrelated to the server's UTC "today".
        var day = new DateOnly(2026, 3, 15);
        var otherDay = new DateOnly(2026, 3, 16);

        List<DailyMission> forDay;
        await using (var db = NewDb())
        {
            forDay = await new MissionService(db).GetTodaysMissions(userId, day);
        }

        Assert.Equal(GameConstants.MissionsPerDay, forDay.Count);
        Assert.All(forDay, m => Assert.Equal(day, m.Date));

        // A different game day produces its own separate set — proving the day parameter drives
        // generation. Under the old UTC-only code both calls would have collided on one day.
        await using (var db = NewDb())
        {
            var forOther = await new MissionService(db).GetTodaysMissions(userId, otherDay);
            Assert.All(forOther, m => Assert.Equal(otherDay, m.Date));
        }

        await using (var check = NewDb())
        {
            var perDay = await check.DailyMissions
                .Where(m => m.UserId == userId)
                .GroupBy(m => m.Date)
                .Select(g => g.Count())
                .ToListAsync();
            Assert.Equal(2, perDay.Count); // two distinct days
            Assert.All(perDay, c => Assert.Equal(GameConstants.MissionsPerDay, c));
        }
    }

    [Fact]
    public async Task Progress_targets_the_supplied_game_days_missions()
    {
        var userId = await SeedUser();
        var day = new DateOnly(2026, 3, 15);

        MissionType presentType;
        await using (var db = NewDb())
        {
            var generated = await new MissionService(db).GetTodaysMissions(userId, day);
            presentType = generated[0].Type; // a type guaranteed to exist for this day
        }

        await using (var db = NewDb())
        {
            var svc = new MissionService(db);
            // A large amount guarantees the mission of that type completes (progress > 0).
            var result = await svc.RecordProgress(userId, presentType, 10_000, day);
            await db.SaveChangesAsync();

            Assert.All(result.Missions, m => Assert.Equal(day, m.Date));
            Assert.Contains(result.Missions, m => m.Type == presentType && m.CurrentProgress > 0);
        }
    }
}
