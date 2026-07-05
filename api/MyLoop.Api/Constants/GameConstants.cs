namespace MyLoop.Api.Constants;

/// <summary>
/// All game-wide constants in one place — no magic numbers scattered in code.
/// </summary>
public static class GameConstants
{
    // --- Territory Claim Rules ---
    public const int MinGpsPointsPerClaim = 10;
    public const int MinPointsForPolygon = 4;
    public const double MinWalkDistanceMeters = 200.0;
    public const double MaxClaimAreaSquareMeters = 5_000_000.0; // 5 km²
    /// <summary>Hard cap on cells assigned in one claim (secondary guard alongside area).</summary>
    public const int MaxCellsPerClaim = 3000;
    public const int MaxClaimsPerDay = 20;
    public const double LoopClosureDistanceMeters = 50.0;
    public const int MinLoopPoints = 20;
    public const int LoopSkipNeighbors = 10;
    public const double MinFillAreaSquareMeters = 5_000.0;
    public const double DeduplicationOverlapThreshold = 0.80;
    /// <summary>
    /// Steal-back protection window: a just-captured cell cannot be stolen for this long.
    /// A full day prevents ping-pong ownership flipping and matches the daily play loop
    /// (missions, streaks, daily leaderboard finishes).
    /// </summary>
    public const double CellCooldownHours = 24.0;

    // --- H3 Hex Grid ---
    /// <summary>
    /// H3 resolution 11: edge ~29m, circumradius ~29m, area ~2,150 m².
    /// Produces edge-to-edge tessellating hexes that feel "earnable" per walk.
    /// </summary>
    public const int H3Resolution = 11;
    public const int H3ParentResolution = 3;
    public const int H3NeighborhoodResolution = 8;
    public const double CellAreaSquareMeters = 2_150.0;

    // --- Decay ---
    /// <summary>Default hex decay for local territory (same city).</summary>
    public const int DecayDays = 7;
    /// <summary>Decay for hexes in a different city but same state/region.</summary>
    public const int DecayDaysOtherCity = 15;
    /// <summary>Decay for hexes in a different state/region but same country.</summary>
    public const int DecayDaysOtherRegion = 30;
    /// <summary>Decay for hexes in a different country but same continent.</summary>
    public const int DecayDaysOtherCountry = 60;
    /// <summary>Decay for hexes on a different continent.</summary>
    public const int DecayDaysOtherContinent = 90;

    /// <summary>
    /// Distance threshold (km) below which we skip geocoding and assume "same city".
    /// </summary>
    public const double SameCityDistanceKm = 30;

    /// <summary>
    /// Returns decay days based on geographic comparison between user's home and hex location.
    /// Uses actual administrative boundaries (city/state/country/continent).
    /// </summary>
    public static int GetDecayDaysFromLocation(
        string homeCity, string homeState, string homeCountry, string homeContinent,
        string hexCity, string hexState, string hexCountry, string hexContinent)
    {
        // Same city → local decay
        if (!string.IsNullOrEmpty(homeCity) && !string.IsNullOrEmpty(hexCity)
            && string.Equals(homeCity, hexCity, StringComparison.OrdinalIgnoreCase))
            return DecayDays;

        // Same state/region → other city decay
        if (!string.IsNullOrEmpty(homeState) && !string.IsNullOrEmpty(hexState)
            && string.Equals(homeState, hexState, StringComparison.OrdinalIgnoreCase))
            return DecayDaysOtherCity;

        // Same country → other region decay
        if (!string.IsNullOrEmpty(homeCountry) && !string.IsNullOrEmpty(hexCountry)
            && string.Equals(homeCountry, hexCountry, StringComparison.OrdinalIgnoreCase))
            return DecayDaysOtherRegion;

        // Same continent → other country decay
        if (!string.IsNullOrEmpty(homeContinent) && !string.IsNullOrEmpty(hexContinent)
            && string.Equals(homeContinent, hexContinent, StringComparison.OrdinalIgnoreCase))
            return DecayDaysOtherCountry;

        // Different continent
        return DecayDaysOtherContinent;
    }

    /// <summary>
    /// Fallback: returns decay days based on raw distance when geocoding is unavailable.
    /// </summary>
    public static int GetDecayDaysForDistance(double distanceKm)
    {
        if (distanceKm < 30) return DecayDays;
        if (distanceKm < 200) return DecayDaysOtherCity;
        if (distanceKm < 1000) return DecayDaysOtherRegion;
        if (distanceKm < 5000) return DecayDaysOtherCountry;
        return DecayDaysOtherContinent;
    }

    /// <summary>Total child cells at res-11 within one res-8 neighborhood hex (7^3 = 343).</summary>
    public const int CellsPerNeighborhood = 343;

    // --- Viewport / Query Limits ---
    public const int MaxViewportCells = 500;
    public const int MaxUserTerritoryCells = 2000;
    public const int MaxPreviewPathLength = 10_000;

    /// <summary>Hard cap on GPS points accepted in a single claim/trail submission (DoS guard).</summary>
    public const int MaxClaimPathPoints = 50_000;

    // --- GPS / Geolocation ---
    public const double EarthRadiusMeters = 6_371_000.0;
    public const double MetersPerDegreeLat = 111_320.0;

    // --- Leaderboard ---
    public const int LeaderboardTopCount = 20;
    public const int LeaderboardRetentionDays = 7;
    public const int MaxHistoryDepth = 50;
    public const int MaxStolenCellsResponse = 200;
    public const int MaxStolenDaysLookback = 30;
    /// <summary>Most-recent days of claim history summarised for the Home "Hex History" section.</summary>
    public const int ClaimHistoryDays = 30;

    // --- Validation ---
    public const int MinDisplayNameLength = 2;
    public const int MaxDisplayNameLength = 20;
    public const int MaxAvatarId = 50;

    /// <summary>
    /// Minimum days between home-location changes. Home drives decay distance and the
    /// city/country leaderboard scope, so unrestricted re-homing lets a player game both
    /// (anti-cheat, #84). The first set (onboarding) is always allowed.
    /// </summary>
    public const int HomeChangeCooldownDays = 30;

    // --- XP & Levels ---
    public const int XpPerHexCaptured = 10;
    public const int XpPerHexStolen = 25;
    public const int XpPerKmWalked = 50;
    public const int XpStreakBonus = 20; // per day of active streak
    public const int XpMissionComplete = 0; // awarded per-mission (varies)
    public const int XpAllMissionsBonus = 100; // bonus for completing all 3 daily
    public const int MissionsPerDay = 3;

    /// <summary>XP threshold to reach a given level. Level 1 = 0 XP, Level 2 = 100 XP, Level 3 = 400 XP, Level 10 = 8100 XP.</summary>
    /// <summary>XP threshold to reach a given level. Level 1 = 0 XP, Level 2 = 100 XP, Level 10 = 8100 XP.</summary>
    public static int XpForLevel(int level) => (level - 1) * (level - 1) * 100;
    public static int LevelFromXp(long xp)
    {
        var level = 1 + (int)Math.Sqrt(xp / 100.0);
        return Math.Max(1, level);
    }
}
