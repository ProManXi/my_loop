using MyLoop.Api.Constants;
using MyLoop.Api.Entities;

namespace MyLoop.Api.Services;

/// <summary>
/// Single source of truth for mutating a user's XP and the level derived from it. Every XP
/// award (mission, claim, achievement) and every reversal must go through here so the
/// <see cref="GameConstants.LevelFromXp"/> mapping is applied in exactly one place — previously
/// both <see cref="MissionService"/> and <see cref="AchievementService"/> duplicated it, which
/// let the two drift and let a conflict-rollback strand XP without recomputing the level
/// (#132 / ML-ERR-035).
/// </summary>
public static class XpLedger
{
    /// <summary>Adds <paramref name="xp"/> to the user and recomputes their level.</summary>
    public static void Grant(User user, int xp)
    {
        user.TotalXp += xp;
        user.Level = GameConstants.LevelFromXp(user.TotalXp);
    }

    /// <summary>
    /// Reverses a previously-granted <paramref name="xp"/> amount (floored at zero) and
    /// recomputes the level. Used when a concurrent unlock forces an achievement row to be
    /// rolled back after its XP was already applied.
    /// </summary>
    public static void Revoke(User user, int xp)
    {
        user.TotalXp = Math.Max(0, user.TotalXp - xp);
        user.Level = GameConstants.LevelFromXp(user.TotalXp);
    }
}
