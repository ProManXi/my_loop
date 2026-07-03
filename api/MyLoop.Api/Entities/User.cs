namespace MyLoop.Api.Entities;

/// <summary>
/// Represents a player in the MyLoop territory game.
/// Each user is identified by their Firebase Auth UID and has a customizable
/// appearance (color + avatar) that is displayed on the territory map and leaderboard.
/// </summary>
public class User
{
    /// <summary>Internal unique identifier for the user (primary key).</summary>
    public Guid Id { get; set; }

    /// <summary>Firebase Authentication UID — links this user to their Firebase identity. Must be unique.</summary>
    public required string FirebaseUid { get; set; }

    /// <summary>Player-chosen display name shown on the map and leaderboard.</summary>
    public required string DisplayName { get; set; }

    /// <summary>Hex color string (e.g., "#FF5733") used to render this player's territory on the map.</summary>
    public required string Color { get; set; }

    /// <summary>Index of the player's selected avatar graphic from the predefined avatar set.</summary>
    public int AvatarId { get; set; }

    /// <summary>Total number of hexes currently owned by this player.</summary>
    public int HexCount { get; set; }

    /// <summary>Lifetime total hexes ever captured (never decreases, even when stolen).</summary>
    public int TotalHexesCaptured { get; set; }

    /// <summary>Current daily walk streak (consecutive days with at least one walk).</summary>
    public int Streak { get; set; }

    /// <summary>Total distance walked in kilometers.</summary>
    public double DistanceKm { get; set; }

    /// <summary>The highest streak this user has ever achieved.</summary>
    public int MaxStreak { get; set; }

    /// <summary>Number of times this user finished in the top 3 of a daily leaderboard.</summary>
    public int TopThreeFinishes { get; set; }

    /// <summary>Number of times this user finished in the top 10 of a daily leaderboard.</summary>
    public int TopTenFinishes { get; set; }

    /// <summary>Number of times this user finished in the top 100 of a daily leaderboard.</summary>
    public int TopHundredFinishes { get; set; }

    /// <summary>Number of times this user finished in the top 1000 of a daily leaderboard.</summary>
    public int TopThousandFinishes { get; set; }

    /// <summary>Whether the user is currently on an active streak today.</summary>
    public bool IsStreakActive { get; set; } = true;

    /// <summary>Date of the user's last successful claim (for streak calculation).</summary>
    public DateOnly? LastClaimDate { get; set; }

    /// <summary>Timestamp when the user account was created (defaults to UTC now).</summary>
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    /// <summary>The city the user registered in (for city-scope leaderboard).</summary>
    public string City { get; set; } = "";

    /// <summary>The country the user is in (for country-scope leaderboard).</summary>
    public string Country { get; set; } = "";

    /// <summary>Latitude of the user's home location (set during onboarding, used for decay distance calculation).</summary>
    public double? HomeLat { get; set; }

    /// <summary>Longitude of the user's home location (set during onboarding, used for decay distance calculation).</summary>
    public double? HomeLng { get; set; }

    /// <summary>Home city name (from reverse geocoding the user's chosen home location).</summary>
    public string HomeCity { get; set; } = "";

    /// <summary>Home state/region name (from reverse geocoding).</summary>
    public string HomeState { get; set; } = "";

    /// <summary>Home country name (from reverse geocoding).</summary>
    public string HomeCountry { get; set; } = "";

    /// <summary>Home continent code (from reverse geocoding).</summary>
    public string HomeContinent { get; set; } = "";

    /// <summary>
    /// When the home location was last set (UTC). Gates re-homing to once per
    /// <see cref="Constants.GameConstants.HomeChangeCooldownDays"/> (anti-cheat, #84).
    /// Null until home is first set (or for accounts that set it before this field existed —
    /// those get one tracked change before the cooldown applies).
    /// </summary>
    public DateTime? HomeSetAt { get; set; }

    /// <summary>Authentication provider used to create this account (e.g., "google", "apple", "local").</summary>
    public string AuthProvider { get; set; } = "local";

    /// <summary>Total hexes stolen from other players (lifetime).</summary>
    public int TotalHexesStolen { get; set; }

    /// <summary>Total days with all daily missions completed.</summary>
    public int AllMissionsCompleteDays { get; set; }

    /// <summary>Total experience points earned lifetime.</summary>
    public long TotalXp { get; set; }

    /// <summary>Current level (computed from TotalXp).</summary>
    public int Level { get; set; } = 1;
}
