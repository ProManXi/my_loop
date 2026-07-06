using MyLoop.Api.Entities;

namespace MyLoop.Api.Models;

/// <summary>
/// Public projection of a <see cref="User"/> — the ONLY shape any user may see for
/// another user. Deliberately excludes every sensitive/PII field on the entity:
/// <c>FirebaseUid</c>, home coordinates (<c>HomeLat/HomeLng</c>) and derived home
/// geography, and <c>LastClaimDate</c>. Home coordinates are where the player lives,
/// so serializing the raw entity to <c>GET /api/users/{id}</c> was a doxxing vector
/// (#100 / ML-ERR-003). Adding a field here makes it public — do so consciously.
/// </summary>
public class UserResponse
{
    public Guid Id { get; set; }
    public string DisplayName { get; set; } = "";
    public string Color { get; set; } = "";
    public int AvatarId { get; set; }
    public int HexCount { get; set; }
    public int TotalHexesCaptured { get; set; }
    public int Streak { get; set; }
    public int MaxStreak { get; set; }
    public double DistanceKm { get; set; }
    public int Level { get; set; }
    public long TotalXp { get; set; }
    public DateTime CreatedAt { get; set; }

    /// <summary>Maps the shared public fields; used by this and derived projections.</summary>
    protected void MapPublicFrom(User user)
    {
        Id = user.Id;
        DisplayName = user.DisplayName;
        Color = user.Color;
        AvatarId = user.AvatarId;
        HexCount = user.HexCount;
        TotalHexesCaptured = user.TotalHexesCaptured;
        Streak = user.Streak;
        MaxStreak = user.MaxStreak;
        DistanceKm = user.DistanceKm;
        Level = user.Level;
        TotalXp = user.TotalXp;
        CreatedAt = user.CreatedAt;
    }

    public static UserResponse FromUser(User user)
    {
        var response = new UserResponse();
        response.MapPublicFrom(user);
        return response;
    }
}
