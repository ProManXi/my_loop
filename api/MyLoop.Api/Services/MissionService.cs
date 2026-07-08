using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Entities;

namespace MyLoop.Api.Services;

public interface IMissionService
{
    /// <param name="gameDay">The player's local day (see <see cref="GameDay"/>). Null falls back to
    /// UTC today for callers that don't supply one.</param>
    Task<List<DailyMission>> GetTodaysMissions(Guid userId, DateOnly? gameDay = null);
    Task<MissionProgressResult> RecordProgress(Guid userId, MissionType type, int amount, DateOnly? gameDay = null);
    Task<XpGainResult> AwardXp(Guid userId, int xp, string reason);
}

public class MissionProgressResult
{
    public List<DailyMission> Missions { get; set; } = [];
    public List<MissionCompleted> JustCompleted { get; set; } = [];
    public int XpEarned { get; set; }
    public bool AllMissionsComplete { get; set; }
    public int BonusXp { get; set; }
}

public class MissionCompleted
{
    public Guid MissionId { get; set; }
    public string Description { get; set; } = "";
    public int XpReward { get; set; }
}

public class XpGainResult
{
    public long TotalXp { get; set; }
    public int Level { get; set; }
    public bool LeveledUp { get; set; }
    public int PreviousLevel { get; set; }
}

public class MissionService : IMissionService
{
    private readonly AppDbContext _db;

    public MissionService(AppDbContext db)
    {
        _db = db;
    }

    public async Task<List<DailyMission>> GetTodaysMissions(Guid userId, DateOnly? gameDay = null)
    {
        var today = gameDay ?? DateOnly.FromDateTime(DateTime.UtcNow);

        var missions = await _db.DailyMissions
            .Where(m => m.UserId == userId && m.Date == today)
            .OrderBy(m => m.Type)
            .ToListAsync();

        if (missions.Count == 0)
        {
            var user = await _db.Users.FindAsync(userId);
            missions = GenerateAdaptiveMissions(userId, today, user);
            _db.DailyMissions.AddRange(missions);
            try
            {
                await _db.SaveChangesAsync();
            }
            catch (DbUpdateException)
            {
                _db.ChangeTracker.Clear();
                missions = await _db.DailyMissions
                    .Where(m => m.UserId == userId && m.Date == today)
                    .OrderBy(m => m.Type)
                    .ToListAsync();
            }
        }

        return missions;
    }

    /// <summary>
    /// Records progress toward missions. Does NOT call SaveChangesAsync —
    /// the caller is responsible for saving (allows single-transaction batching).
    /// </summary>
    public async Task<MissionProgressResult> RecordProgress(Guid userId, MissionType type, int amount, DateOnly? gameDay = null)
    {
        var today = gameDay ?? DateOnly.FromDateTime(DateTime.UtcNow);
        var missions = await _db.DailyMissions
            .Where(m => m.UserId == userId && m.Date == today)
            .ToListAsync();

        if (missions.Count == 0)
        {
            // Missions not yet generated (first claim of the day) — generate now
            var user = await _db.Users.FindAsync(userId);
            missions = GenerateAdaptiveMissions(userId, today, user);
            _db.DailyMissions.AddRange(missions);
        }

        var result = new MissionProgressResult { Missions = missions };
        var matchingMissions = missions.Where(m => m.Type == type && !m.IsCompleted).ToList();

        foreach (var mission in matchingMissions)
        {
            // CaptureInOneWalk is scored as the best SINGLE walk, so the caller passes that walk's
            // cumulative captured total and we keep the maximum — several small walks must not add
            // up to complete a "capture N in ONE walk" mission (#108). Every other type is additive.
            mission.CurrentProgress = IsMaxOfSession(type)
                ? Math.Max(mission.CurrentProgress, amount)
                : mission.CurrentProgress + amount;
            if (mission.CurrentProgress >= mission.TargetValue && !mission.IsCompleted)
            {
                mission.CompletedAt = DateTime.UtcNow;
                mission.CurrentProgress = mission.TargetValue;
                result.JustCompleted.Add(new MissionCompleted
                {
                    MissionId = mission.Id,
                    Description = mission.Description,
                    XpReward = mission.XpReward,
                });
                result.XpEarned += mission.XpReward;
            }
        }

        // All-missions bonus: only if we JUST completed one and now all are done
        if (result.JustCompleted.Count > 0 && missions.All(m => m.IsCompleted))
        {
            result.AllMissionsComplete = true;
            result.BonusXp = GameConstants.XpAllMissionsBonus;
            result.XpEarned += result.BonusXp;

            // Denormalized counter for achievement tracking
            var user = await _db.Users.FindAsync(userId);
            if (user != null) user.AllMissionsCompleteDays += 1;
        }

        // Award mission-completion XP to user entity (no save yet)
        if (result.XpEarned > 0)
        {
            await AwardXpInternal(userId, result.XpEarned);
        }

        return result;
    }

    /// <summary>
    /// CaptureInOneWalk is the only mission scored as the maximum of a single walk's total rather
    /// than a running sum across the day (#108), so callers pass that walk's cumulative captured
    /// count (its Claim.CellCount). Every other type accumulates additively.
    /// </summary>
    private static bool IsMaxOfSession(MissionType type) => type == MissionType.CaptureInOneWalk;

    /// <summary>
    /// Awards XP and saves all pending changes (hex claim + missions + XP) in one transaction.
    /// </summary>
    public async Task<XpGainResult> AwardXp(Guid userId, int xp, string reason)
    {
        var result = await AwardXpInternal(userId, xp);
        try
        {
            await _db.SaveChangesAsync();
        }
        catch (DbUpdateException)
        {
            // A concurrent writer already inserted one of the achievement rows we're adding,
            // so the unique (UserId, AchievementId) index rejected the save. We detach the
            // losing rows and retry — but AchievementService already applied each unlock's XP
            // to user.TotalXp. Detaching the row WITHOUT reversing that XP would leave the user
            // permanently credited for an achievement they no longer own (double-award relative
            // to the winning writer). So revoke each detached unlock's XP first.
            var user = await _db.Users.FindAsync(userId);
            var conflicting = _db.ChangeTracker.Entries<UserAchievement>()
                .Where(e => e.State == EntityState.Added)
                .ToList();
            foreach (var entry in conflicting)
            {
                if (user != null)
                    XpLedger.Revoke(user, entry.Entity.XpAwarded);
                entry.State = EntityState.Detached;
            }
            await _db.SaveChangesAsync();

            // Reflect the corrected totals in the result the caller pushes to the client.
            if (user != null)
            {
                result.TotalXp = user.TotalXp;
                result.LeveledUp = user.Level > result.PreviousLevel;
                result.Level = user.Level;
            }
        }
        return result;
    }

    private async Task<XpGainResult> AwardXpInternal(Guid userId, int xp)
    {
        var user = await _db.Users.FindAsync(userId);
        if (user == null) return new XpGainResult();

        var previousLevel = user.Level;
        XpLedger.Grant(user, xp);

        return new XpGainResult
        {
            TotalXp = user.TotalXp,
            Level = user.Level,
            LeveledUp = user.Level > previousLevel,
            PreviousLevel = previousLevel,
        };
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADAPTIVE MISSION GENERATION
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Algorithm: Player Profile → Tier → Weighted Template Selection
    //
    // 1. Determine player tier from stats (Newcomer → Regular → Veteran → Elite)
    // 2. Scale mission difficulty to tier (easy targets for newcomers, hard for veterans)
    // 3. Weight mission TYPES based on player behavior:
    //    - Core strength missions (what they already do) → 60% weight → keeps them engaged
    //    - Growth missions (nudge toward new behaviors) → 30% weight → expands gameplay
    //    - Streak/maintenance missions → 10% weight → retention anchor
    // 4. Select 3 missions ensuring type diversity (no two identical types)
    //
    // Research basis: Csikszentmihalyi Flow theory + Bartle player taxonomy adaptation

    private List<DailyMission> GenerateAdaptiveMissions(Guid userId, DateOnly date, User? user)
    {
        var bytes = userId.ToByteArray();
        var seed = BitConverter.ToInt32(bytes, 0) ^ BitConverter.ToInt32(bytes, 4) ^ date.DayNumber;
        var rng = new Random(seed);

        var tier = ClassifyPlayerTier(user);
        var weights = ComputeBehaviorWeights(user, tier);
        var templates = GetAdaptiveTemplates(tier);

        // Weighted selection with type diversity enforcement
        var selected = new List<MissionTemplate>(GameConstants.MissionsPerDay);
        var usedTypes = new HashSet<MissionType>();

        for (var i = 0; i < GameConstants.MissionsPerDay; i++)
        {
            var candidates = templates
                .Where(t => !usedTypes.Contains(t.Type))
                .ToList();

            if (candidates.Count == 0)
                candidates = templates; // Fallback if we exhaust unique types

            var chosen = WeightedSelect(candidates, weights, rng);
            selected.Add(chosen);
            usedTypes.Add(chosen.Type);
        }

        return selected.Select(t => new DailyMission
        {
            Id = Guid.NewGuid(),
            UserId = userId,
            Date = date,
            Type = t.Type,
            TargetValue = t.Target,
            CurrentProgress = 0,
            XpReward = t.Xp,
            Description = t.Description,
        }).ToList();
    }

    private static PlayerTier ClassifyPlayerTier(User? user)
    {
        if (user == null) return PlayerTier.Newcomer;

        var daysPlaying = (DateTime.UtcNow - user.CreatedAt).TotalDays;
        var totalHexes = user.TotalHexesCaptured;

        return (daysPlaying, totalHexes) switch
        {
            ( < 7, _) => PlayerTier.Newcomer,
            (_, < 50) => PlayerTier.Newcomer,
            ( < 30, < 500) => PlayerTier.Regular,
            (_, < 500) => PlayerTier.Regular,
            ( < 60, _) => PlayerTier.Veteran,
            (_, < 2000) => PlayerTier.Veteran,
            _ => PlayerTier.Elite,
        };
    }

    /// <summary>
    /// Computes per-type weights based on player's actual behavior patterns.
    /// High weight = more likely to be selected.
    /// </summary>
    private static Dictionary<MissionType, double> ComputeBehaviorWeights(User? user, PlayerTier tier)
    {
        // Base weights: everyone gets some of each type
        var weights = new Dictionary<MissionType, double>
        {
            [MissionType.CaptureHexes] = 1.0,
            [MissionType.WalkDistance] = 1.0,
            [MissionType.StealHex] = 0.5,
            [MissionType.ExploreNewArea] = 0.8,
            [MissionType.MaintainStreak] = 0.6,
            [MissionType.CaptureInOneWalk] = 0.7,
        };

        if (user == null) return weights;

        // --- Boost core strengths (60% principle: keep players doing what they love) ---

        // Heavy walker → boost distance missions
        if (user.DistanceKm > 50) weights[MissionType.WalkDistance] += 0.8;
        // Territory dominator → boost capture missions
        if (user.TotalHexesCaptured > 200) weights[MissionType.CaptureHexes] += 0.5;
        // Aggressive player → boost steal missions
        if (user.TopThreeFinishes > 5) weights[MissionType.StealHex] += 0.8;

        // --- Nudge toward growth behaviors (30% principle: expand engagement) ---

        // Low streak → nudge them to build habit
        if (user.Streak < 3 && user.IsStreakActive)
            weights[MissionType.MaintainStreak] += 1.0;
        // Never steals → occasional nudge (but don't overwhelm)
        if (user.TopThreeFinishes == 0 && tier >= PlayerTier.Regular)
            weights[MissionType.StealHex] += 0.4;
        // Low exploration → encourage discovery
        if (user.HexCount < 100 && tier >= PlayerTier.Regular)
            weights[MissionType.ExploreNewArea] += 0.6;

        // --- Streak at risk → prioritize retention anchor ---
        if (user.IsStreakActive && user.Streak >= 5)
            weights[MissionType.MaintainStreak] += 0.5;

        // --- Newcomer protection: reduce intimidating mission types ---
        if (tier == PlayerTier.Newcomer)
        {
            weights[MissionType.StealHex] = 0.1; // Don't ask newbies to steal
            weights[MissionType.CaptureInOneWalk] = 0.2;
        }

        return weights;
    }

    /// <summary>
    /// Returns templates scaled to player tier difficulty.
    /// </summary>
    private static List<MissionTemplate> GetAdaptiveTemplates(PlayerTier tier)
    {
        return tier switch
        {
            PlayerTier.Newcomer =>
            [
                new(MissionType.CaptureHexes, 2, 40, "Capture 2 hexes"),
                new(MissionType.CaptureHexes, 3, 60, "Capture 3 hexes"),
                new(MissionType.WalkDistance, 200, 40, "Walk 200 meters"),
                new(MissionType.WalkDistance, 400, 60, "Walk 400 meters"),
                new(MissionType.ExploreNewArea, 1, 80, "Explore a new area"),
                new(MissionType.MaintainStreak, 1, 50, "Keep your streak alive"),
                new(MissionType.CaptureInOneWalk, 2, 60, "Capture 2 hexes in one walk"),
                new(MissionType.StealHex, 1, 60, "Steal a hex from another player"),
            ],
            PlayerTier.Regular =>
            [
                new(MissionType.CaptureHexes, 5, 80, "Capture 5 hexes"),
                new(MissionType.CaptureHexes, 8, 120, "Capture 8 hexes"),
                new(MissionType.WalkDistance, 500, 70, "Walk 500 meters"),
                new(MissionType.WalkDistance, 1000, 120, "Walk 1 kilometer"),
                new(MissionType.StealHex, 1, 80, "Steal a hex from a rival"),
                new(MissionType.StealHex, 2, 120, "Steal 2 hexes from rivals"),
                new(MissionType.ExploreNewArea, 2, 100, "Explore 2 new areas"),
                new(MissionType.MaintainStreak, 1, 60, "Maintain your streak"),
                new(MissionType.CaptureInOneWalk, 5, 100, "Capture 5 hexes in one walk"),
            ],
            PlayerTier.Veteran =>
            [
                new(MissionType.CaptureHexes, 10, 120, "Capture 10 hexes"),
                new(MissionType.CaptureHexes, 15, 180, "Capture 15 hexes"),
                new(MissionType.WalkDistance, 1000, 100, "Walk 1 kilometer"),
                new(MissionType.WalkDistance, 2000, 180, "Walk 2 kilometers"),
                new(MissionType.StealHex, 2, 120, "Steal 2 hexes from rivals"),
                new(MissionType.StealHex, 5, 200, "Steal 5 hexes — go on offense"),
                new(MissionType.ExploreNewArea, 3, 150, "Explore 3 new areas"),
                new(MissionType.MaintainStreak, 1, 80, "Keep the streak going"),
                new(MissionType.CaptureInOneWalk, 8, 150, "Capture 8 hexes in one walk"),
            ],
            PlayerTier.Elite =>
            [
                new(MissionType.CaptureHexes, 15, 150, "Capture 15 hexes"),
                new(MissionType.CaptureHexes, 25, 250, "Dominate: capture 25 hexes"),
                new(MissionType.WalkDistance, 2000, 150, "Walk 2 kilometers"),
                new(MissionType.WalkDistance, 3000, 250, "Walk 3 kilometers"),
                new(MissionType.StealHex, 5, 200, "Steal 5 hexes from the leaderboard"),
                new(MissionType.StealHex, 10, 350, "Launch a raid: steal 10 hexes"),
                new(MissionType.ExploreNewArea, 5, 200, "Explore 5 new areas"),
                new(MissionType.MaintainStreak, 1, 100, "Protect your streak"),
                new(MissionType.CaptureInOneWalk, 12, 200, "Power walk: 12 hexes in one session"),
            ],
            _ => GetAdaptiveTemplates(PlayerTier.Regular),
        };
    }

    private static MissionTemplate WeightedSelect(
        List<MissionTemplate> candidates,
        Dictionary<MissionType, double> weights,
        Random rng)
    {
        var totalWeight = candidates.Sum(c => weights.GetValueOrDefault(c.Type, 1.0));
        var roll = rng.NextDouble() * totalWeight;
        var cumulative = 0.0;

        foreach (var candidate in candidates)
        {
            cumulative += weights.GetValueOrDefault(candidate.Type, 1.0);
            if (roll <= cumulative)
                return candidate;
        }

        return candidates[^1]; // Fallback
    }

    private enum PlayerTier { Newcomer, Regular, Veteran, Elite }
    private record MissionTemplate(MissionType Type, int Target, int Xp, string Description);
}
