using System.Text.Json;
using MyLoop.Api.Entities;
using MyLoop.Api.Models;
using Xunit;

namespace MyLoop.Api.Tests;

/// <summary>
/// #100 / ML-ERR-003: user payloads must never leak PII. These assert on the SERIALIZED
/// JSON (not the DTO type) so a future field added to a projection can't silently
/// re-expose a sensitive key.
/// </summary>
public class UserResponseSerializationTests
{
    // Never allowed on ANY user payload: the Firebase identity and raw home coordinates.
    private static readonly string[] ForbiddenEverywhere =
    {
        "firebaseUid", "homeLat", "homeLng", "homeState",
        "homeCountry", "homeContinent", "homeSetAt",
    };

    private static User FullUser() => new()
    {
        Id = Guid.NewGuid(),
        FirebaseUid = "secret-uid",
        DisplayName = "Robin",
        Color = "#FF0000",
        AvatarId = 2,
        HexCount = 10,
        TotalHexesCaptured = 12,
        Streak = 3,
        MaxStreak = 5,
        DistanceKm = 4.2,
        Level = 6,
        TotalXp = 1234,
        City = "Austin",
        Country = "USA",
        HomeCity = "Austin",
        HomeState = "TX",
        HomeCountry = "USA",
        HomeContinent = "NA",
        HomeLat = 30.26,
        HomeLng = -97.74,
        IsStreakActive = true,
        LastClaimDate = new DateOnly(2026, 7, 5),
    };

    private static ICollection<string> SerializedKeys(object dto)
    {
        var json = JsonSerializer.Serialize(dto, dto.GetType());
        return JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json)!.Keys;
    }

    [Fact]
    public void UserResponse_public_projection_exposes_only_public_fields()
    {
        var keys = SerializedKeys(UserResponse.FromUser(FullUser()));

        foreach (var forbidden in ForbiddenEverywhere)
            Assert.DoesNotContain(forbidden, keys, StringComparer.OrdinalIgnoreCase);

        // The public projection must not carry ANY home geography or private fields —
        // this is the payload an arbitrary user gets for GET /api/users/{otherUser}.
        foreach (var privateKey in new[] { "homeCity", "city", "country", "lastClaimDate", "isStreakActive" })
            Assert.DoesNotContain(privateKey, keys, StringComparer.OrdinalIgnoreCase);

        Assert.Contains("displayName", keys, StringComparer.OrdinalIgnoreCase);
        Assert.Contains("hexCount", keys, StringComparer.OrdinalIgnoreCase);
    }

    [Fact]
    public void UserSelfResponse_owner_projection_has_no_uid_or_raw_home_coords()
    {
        var keys = SerializedKeys(UserSelfResponse.FromUser(FullUser()));

        foreach (var forbidden in ForbiddenEverywhere)
            Assert.DoesNotContain(forbidden, keys, StringComparer.OrdinalIgnoreCase);

        // The owner legitimately gets these non-PII private fields (home CITY name only,
        // never raw lat/lng).
        Assert.Contains("homeCity", keys, StringComparer.OrdinalIgnoreCase);
        Assert.Contains("city", keys, StringComparer.OrdinalIgnoreCase);
        Assert.Contains("lastClaimDate", keys, StringComparer.OrdinalIgnoreCase);
    }
}
