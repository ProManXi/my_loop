using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;

namespace MyLoop.Api.Services;

public interface IAchievementService
{
    /// <summary>
    /// Checks all achievements against the user's current stats and unlocks any newly earned.
    /// Call after any stat-changing action (hex capture, level up, streak update).
    /// Returns list of newly unlocked achievements (for client notification).
    /// Does NOT call SaveChangesAsync — caller is responsible.
    /// </summary>
    Task<List<AchievementUnlock>> CheckAndUnlock(Guid userId);

    /// <summary>Gets all achievements with user's unlock status.</summary>
    Task<List<AchievementStatus>> GetAllForUser(Guid userId);
}

public class AchievementUnlock
{
    public string AchievementId { get; set; } = "";
    public string Name { get; set; } = "";
    public string Icon { get; set; } = "";
    public int XpAwarded { get; set; }
}

public class AchievementStatus
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public string Icon { get; set; } = "";
    public int Category { get; set; }
    public int Threshold { get; set; }
    public int XpReward { get; set; }
    public bool Unlocked { get; set; }
    public DateTime? UnlockedAt { get; set; }
    public double Progress { get; set; }
}

public class AchievementService : IAchievementService
{
    private readonly AppDbContext _db;

    public AchievementService(AppDbContext db)
    {
        _db = db;
    }

    public async Task<List<AchievementUnlock>> CheckAndUnlock(Guid userId)
    {
        var user = await _db.Users.FindAsync(userId);
        if (user == null) return [];

        var alreadyUnlocked = await _db.UserAchievements
            .Where(a => a.UserId == userId)
            .Select(a => a.AchievementId)
            .ToHashSetAsync();

        var newUnlocks = new List<AchievementUnlock>();

        // Convergence loop: achievements awarding XP can trigger level achievements
        int previousCount;
        int iteration = 0;
        do
        {
            previousCount = newUnlocks.Count;
            foreach (var def in Achievements.All)
            {
                if (alreadyUnlocked.Contains(def.Id)) continue;

                var currentValue = GetCurrentValue(def, user);
                if (currentValue < def.Threshold) continue;

                // Unlock!
                alreadyUnlocked.Add(def.Id);
                _db.UserAchievements.Add(new UserAchievement
                {
                    Id = Guid.NewGuid(),
                    UserId = userId,
                    AchievementId = def.Id,
                    UnlockedAt = DateTime.UtcNow,
                    XpAwarded = def.XpReward,
                });

                XpLedger.Grant(user, def.XpReward);

                newUnlocks.Add(new AchievementUnlock
                {
                    AchievementId = def.Id,
                    Name = def.Name,
                    Icon = def.Icon,
                    XpAwarded = def.XpReward,
                });
            }
            iteration++;
        } while (newUnlocks.Count > previousCount && iteration < 5); // Safety bound: max 5 convergence passes

        return newUnlocks;
    }

    public async Task<List<AchievementStatus>> GetAllForUser(Guid userId)
    {
        var user = await _db.Users.FindAsync(userId);
        if (user == null) return [];

        var unlocked = await _db.UserAchievements
            .Where(a => a.UserId == userId)
            .ToDictionaryAsync(a => a.AchievementId);

        return Achievements.All.Select(def =>
        {
            var currentValue = GetCurrentValue(def, user);
            var isUnlocked = unlocked.ContainsKey(def.Id);
            return new AchievementStatus
            {
                Id = def.Id,
                Name = def.Name,
                Description = def.Description,
                Icon = def.Icon,
                Category = (int)def.Category,
                Threshold = def.Threshold,
                XpReward = def.XpReward,
                Unlocked = isUnlocked,
                UnlockedAt = isUnlocked ? unlocked[def.Id].UnlockedAt : null,
                Progress = Math.Min(1.0, (double)currentValue / def.Threshold),
            };
        }).ToList();
    }

    private static int GetCurrentValue(AchievementDefinition def, User user)
    {
        return def.Category switch
        {
            AchievementCategory.Capture => user.TotalHexesCaptured,
            AchievementCategory.Streak => user.MaxStreak,
            AchievementCategory.Distance => (int)user.DistanceKm,
            AchievementCategory.Pvp => user.TotalHexesStolen,
            AchievementCategory.Level => user.Level,
            AchievementCategory.Leaderboard => user.TopThreeFinishes,
            AchievementCategory.Missions => user.AllMissionsCompleteDays,
            _ => 0,
        };
    }
}
