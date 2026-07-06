using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;
using MyLoop.Api.Services;
using Testcontainers.PostgreSql;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// #132 / ML-ERR-035: AchievementService applies an unlock's XP to the user directly, then
/// MissionService.AwardXp saves everything. If a concurrent writer already inserted the same
/// UserAchievement row, the unique (UserId, AchievementId) index rejects the save; the handler
/// detaches the losing row and retries. Before the fix it left the XP applied — so the user kept
/// XP for an achievement they no longer owned. The handler must now reverse that XP too.
/// </summary>
public class AchievementXpConflictTests : IAsyncLifetime
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

    [Fact]
    public async Task Conflicting_unlock_is_rolled_back_without_stranding_its_xp()
    {
        // A capture achievement whose threshold the user has crossed: "first_capture" (+25 XP).
        const string achievementId = "first_capture";
        const int achievementXp = 25;
        const int missionXp = 40;

        var userId = Guid.NewGuid();
        await using (var seed = NewDb())
        {
            seed.Users.Add(new User
            {
                Id = userId,
                FirebaseUid = $"uid-{userId}",
                DisplayName = "U",
                Color = "#111111",
                TotalHexesCaptured = 1, // crosses first_capture threshold (1)
                TotalXp = 0,
                Level = 1,
            });
            await seed.SaveChangesAsync();
        }

        await using var db = NewDb();
        var achievements = new AchievementService(db);
        var missions = new MissionService(db);

        // The user's own request unlocks the achievement: adds the row + applies its XP to the
        // tracked user (not yet saved).
        var unlocked = await achievements.CheckAndUnlock(userId);
        Assert.Contains(unlocked, u => u.AchievementId == achievementId);

        // A concurrent writer commits the SAME unlock first, from a separate context.
        await using (var other = NewDb())
        {
            other.UserAchievements.Add(new UserAchievement
            {
                Id = Guid.NewGuid(),
                UserId = userId,
                AchievementId = achievementId,
                UnlockedAt = DateTime.UtcNow,
                XpAwarded = achievementXp,
            });
            await other.SaveChangesAsync();
        }

        // Now award mission XP and flush. The pending UserAchievement add collides with the
        // row the other writer committed → DbUpdateException → the handler detaches it and must
        // reverse the achievement's XP before retrying.
        await missions.AwardXp(userId, missionXp, "test");

        await using var verify = NewDb();
        var user = await verify.Users.FindAsync(userId);
        Assert.NotNull(user);
        // Exactly the mission XP survives — the rolled-back achievement's 25 XP was reversed,
        // not stranded on the user.
        Assert.Equal(missionXp, user!.TotalXp);
        Assert.Equal(GameConstants.LevelFromXp(missionXp), user.Level);

        // Exactly one achievement row exists (the winning writer's), and it's unique.
        var rows = await verify.UserAchievements
            .Where(a => a.UserId == userId && a.AchievementId == achievementId)
            .CountAsync();
        Assert.Equal(1, rows);
    }
}
