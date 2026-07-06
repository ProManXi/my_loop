using MyLoop.Api.Entities;

namespace MyLoop.Api.Models;

/// <summary>
/// Projection the OWNER sees of their own account (register, self-lookup, self-update).
/// Extends <see cref="UserResponse"/> with the private, non-PII fields the owner
/// legitimately needs, but still NEVER exposes <c>FirebaseUid</c> or raw home
/// coordinates: the client already knows what it submitted, and home lat/lng is
/// echoed back only by <c>SetHome</c> during onboarding (#100 / ML-ERR-003).
/// </summary>
public class UserSelfResponse : UserResponse
{
    public string City { get; set; } = "";
    public string Country { get; set; } = "";
    public string HomeCity { get; set; } = "";
    public bool IsStreakActive { get; set; }
    public DateOnly? LastClaimDate { get; set; }

    public static new UserSelfResponse FromUser(User user)
    {
        var response = new UserSelfResponse();
        response.MapPublicFrom(user);
        response.City = user.City;
        response.Country = user.Country;
        response.HomeCity = user.HomeCity;
        response.IsStreakActive = user.IsStreakActive;
        response.LastClaimDate = user.LastClaimDate;
        return response;
    }
}
