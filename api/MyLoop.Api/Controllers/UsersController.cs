using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using MyLoop.Api.Constants;
using MyLoop.Api.Data;
using MyLoop.Api.Models;
using MyLoop.Api.Services;

namespace MyLoop.Api.Controllers;

/// <summary>
/// Handles user registration, profile lookup, and profile updates.
/// </summary>
[ApiController]
[Route("api/users")]
[Authorize]
public class UsersController : ControllerBase
{
    private readonly IUserService _userService;
    private readonly IValidationService _validation;
    private readonly IPushNotificationService _pushService;
    private readonly GeocodingService _geocoding;
    private readonly AppDbContext _db;
    private readonly ICurrentUser _currentUser;
    private readonly ILogger<UsersController> _logger;

    public UsersController(IUserService userService, IValidationService validation,
        IPushNotificationService pushService, GeocodingService geocoding, AppDbContext db,
        ICurrentUser currentUser, ILogger<UsersController> logger)
    {
        _userService = userService;
        _validation = validation;
        _pushService = pushService;
        _geocoding = geocoding;
        _db = db;
        _currentUser = currentUser;
        _logger = logger;
    }

    /// <summary>
    /// Returns Unauthorized/Forbid when the caller is not the user named in the route;
    /// null when the caller owns the resource and the request may proceed.
    /// </summary>
    private async Task<IActionResult?> DenySelf(Guid routeUserId)
    {
        var callerId = await _currentUser.TryGetUserIdAsync();
        if (callerId is null) return Unauthorized();
        if (routeUserId != callerId)
        {
            _logger.LogWarning("Cross-user access denied: caller {CallerId} targeted account {RouteUserId}",
                callerId, routeUserId);
            return Forbid();
        }
        return null;
    }

    /// <summary>
    /// Register a new user. Called once after sign-in.
    /// </summary>
    [AllowAnonymous]
    [HttpPost("register")]
    public async Task<IActionResult> Register([FromBody] RegisterRequest request)
    {
        // Validate inputs
        var nameError = _validation.ValidateDisplayName(request.DisplayName);
        if (nameError != null) return BadRequest(nameError);

        var colorError = _validation.ValidateColor(request.Color);
        if (colorError != null) return BadRequest(colorError);

        var avatarError = _validation.ValidateAvatarId(request.AvatarId);
        if (avatarError != null) return BadRequest(avatarError);

        // Identity is derived ONLY from the validated Firebase token, never from the request body.
        // The endpoint is [AllowAnonymous] so authentication (not authorization) still runs, so a
        // genuine Sign-in-with-Apple/Google caller arrives with a validated token. Trusting the
        // body's FirebaseUid instead let an anonymous caller pre-register a victim's known UID to
        // squat the account, or — if it already existed — read the victim's record straight back
        // (home coordinates are PII in a location game). See #99 / ML-ERR-001.
        var verifiedUid = _currentUser.FirebaseUid;
        string firebaseUid;
        string authProvider;
        if (!string.IsNullOrEmpty(verifiedUid))
        {
            firebaseUid = verifiedUid;
            authProvider = request.AuthProvider ?? "firebase";
        }
        else if (IsLocalRegistration(request.FirebaseUid))
        {
            // No token: the offline/local account path. Mint the uid server-side so it can never
            // collide with — or reveal — a real Firebase account.
            firebaseUid = $"local_{Guid.NewGuid():N}";
            authProvider = "local";
        }
        else
        {
            _logger.LogWarning("Rejected register: client supplied a Firebase UID with no validated token");
            return Unauthorized("A Firebase account must be registered with a valid ID token.");
        }

        var user = await _userService.Register(request, firebaseUid, authProvider);
        _logger.LogInformation("New user registered: {UserId}", user.Id);
        // Owner sees their own account → self projection (no FirebaseUid / home coords).
        return Created($"/api/users/{user.Id}", UserSelfResponse.FromUser(user));
    }

    /// <summary>
    /// True when the request represents a local/dev account (no Firebase identity): an absent uid
    /// or one carrying the reserved local/dev prefixes. Any other client-supplied value is a
    /// real-looking Firebase UID, which is only trustworthy from a validated token — not the body.
    /// </summary>
    private static bool IsLocalRegistration(string? claimedUid) =>
        string.IsNullOrWhiteSpace(claimedUid)
        || claimedUid.StartsWith("dev_", StringComparison.Ordinal)
        || claimedUid.StartsWith("local_", StringComparison.Ordinal);

    /// <summary>
    /// Get a user by their internal ID.
    /// </summary>
    [HttpGet("{id:guid}")]
    public async Task<IActionResult> GetById([FromRoute] Guid id)
    {
        var user = await _userService.GetById(id);
        if (user == null) return NotFound();
        // Any authenticated user can call this for any id → public projection only.
        return Ok(UserResponse.FromUser(user));
    }

    /// <summary>
    /// Look up a user by Firebase UID — used for login.
    /// </summary>
    [HttpGet("by-uid/{firebaseUid}")]
    public async Task<IActionResult> GetByFirebaseUid([FromRoute] string firebaseUid)
    {
        // A caller may only look up their own record by Firebase UID.
        if (!string.Equals(firebaseUid, _currentUser.FirebaseUid, StringComparison.Ordinal))
        {
            _logger.LogWarning("Cross-user UID lookup denied: caller {CallerUid} requested another UID",
                _currentUser.FirebaseUid);
            return Forbid();
        }

        var user = await _userService.GetByFirebaseUid(firebaseUid);
        if (user == null) return NotFound();
        // Self-only (guarded above) → owner projection.
        return Ok(UserSelfResponse.FromUser(user));
    }

    /// <summary>
    /// Update a user's avatar, color, or display name.
    /// </summary>
    [HttpPatch("{id:guid}")]
    public async Task<IActionResult> Update([FromRoute] Guid id, [FromBody] UpdateUserRequest request)
    {
        if (await DenySelf(id) is { } deny) return deny;

        // Validate any provided fields
        if (request.DisplayName != null)
        {
            var nameError = _validation.ValidateDisplayName(request.DisplayName);
            if (nameError != null) return BadRequest(nameError);
        }
        if (request.Color != null)
        {
            var colorError = _validation.ValidateColor(request.Color);
            if (colorError != null) return BadRequest(colorError);
        }
        if (request.AvatarId != null)
        {
            var avatarError = _validation.ValidateAvatarId(request.AvatarId.Value);
            if (avatarError != null) return BadRequest(avatarError);
        }

        var user = await _userService.UpdateProfile(id, request);
        if (user == null) return NotFound();
        // Self-only (DenySelf above) → owner projection.
        return Ok(UserSelfResponse.FromUser(user));
    }

    /// <summary>
    /// Get a user's rich public profile (includes rank, stats, etc.)
    /// </summary>
    [HttpGet("{id:guid}/profile")]
    public async Task<IActionResult> GetProfile([FromRoute] Guid id)
    {
        var profile = await _userService.GetRichProfile(id);
        if (profile == null) return NotFound();
        return Ok(profile);
    }

    /// <summary>
    /// Delete user account and all associated data.
    /// Apple App Store Guideline 5.1.1(v) requires this.
    /// </summary>
    [HttpDelete("{id:guid}")]
    public async Task<IActionResult> DeleteAccount([FromRoute] Guid id)
    {
        if (await DenySelf(id) is { } deny) return deny;

        var deleted = await _userService.DeleteAccount(id);
        if (!deleted) return NotFound();
        _logger.LogInformation("Account deleted: {UserId}", id);
        return NoContent();
    }

    /// <summary>
    /// Register a device token for push notifications.
    /// </summary>
    [HttpPost("{id:guid}/device-token")]
    public async Task<IActionResult> RegisterDeviceToken(
        [FromRoute] Guid id, [FromBody] DeviceTokenRequest request)
    {
        if (await DenySelf(id) is { } deny) return deny;

        if (string.IsNullOrWhiteSpace(request.Token)) return BadRequest("Token is required");
        await _pushService.RegisterDeviceToken(id, request.Token, request.Platform ?? "ios");
        return Ok();
    }

    /// <summary>
    /// Set the user's home location. Called during onboarding.
    /// Reverse geocodes the coordinates to determine city/state/country/continent.
    /// Home drives decay distance and leaderboard scoping, so changes are gated to once
    /// per <see cref="GameConstants.HomeChangeCooldownDays"/> and audited (anti-cheat, #84).
    /// </summary>
    [HttpPost("{id:guid}/home")]
    public async Task<IActionResult> SetHome([FromRoute] Guid id, [FromBody] SetHomeRequest request)
    {
        if (await DenySelf(id) is { } deny) return deny;

        if (request.Lat < -90 || request.Lat > 90 || request.Lng < -180 || request.Lng > 180)
            return BadRequest("Invalid coordinates");

        var user = await _db.Users.FindAsync(id);
        if (user == null) return NotFound();

        var cooldownEnds = user.HomeSetAt?.AddDays(GameConstants.HomeChangeCooldownDays);
        if (cooldownEnds > DateTime.UtcNow)
        {
            _logger.LogWarning(
                "Home change rejected for {UserId}: cooldown until {CooldownEnds} (requested {Lat},{Lng})",
                id, cooldownEnds, request.Lat, request.Lng);
            return StatusCode(StatusCodes.Status429TooManyRequests,
                $"Home location can only be changed once every {GameConstants.HomeChangeCooldownDays} days");
        }

        if (user.HomeLat == null)
        {
            _logger.LogInformation("Home set for {UserId}: ({Lat},{Lng})", id, request.Lat, request.Lng);
        }
        else
        {
            // Audit trail for anti-cheat review: re-homing moves decay distance (and, for
            // legacy accounts with empty City/Country, the leaderboard scope).
            _logger.LogWarning(
                "Home CHANGED for {UserId}: ({OldLat},{OldLng}) -> ({NewLat},{NewLng})",
                id, user.HomeLat, user.HomeLng, request.Lat, request.Lng);
        }

        // Reverse geocode to get city/state/country
        var location = await _geocoding.GetLocationInfo(request.Lat, request.Lng);

        user.HomeLat = request.Lat;
        user.HomeLng = request.Lng;
        user.HomeCity = location.City;
        user.HomeState = location.State;
        user.HomeCountry = location.Country;
        user.HomeContinent = location.Continent;
        user.HomeSetAt = DateTime.UtcNow;

        // Also set City/Country for leaderboards if not already set
        if (string.IsNullOrEmpty(user.City))
            user.City = location.City;
        if (string.IsNullOrEmpty(user.Country))
            user.Country = location.Country;

        await _db.SaveChangesAsync();

        return Ok(new
        {
            user.HomeLat,
            user.HomeLng,
            user.HomeCity,
            user.HomeState,
            user.HomeCountry,
            user.HomeContinent
        });
    }

    /// <summary>
    /// Get a user's walk (claim) history, most recent first.
    /// </summary>
    [HttpGet("{id:guid}/claims")]
    public async Task<IActionResult> GetClaims(
        [FromRoute] Guid id, [FromQuery] int page = 1, [FromQuery] int pageSize = 20)
    {
        if (await DenySelf(id) is { } deny) return deny;

        if (pageSize > 50) pageSize = 50;
        if (page < 1) page = 1;

        var claims = await _db.Claims
            .Where(c => c.UserId == id)
            .OrderByDescending(c => c.CreatedAt)
            .Skip((page - 1) * pageSize)
            .Take(pageSize)
            .Select(c => new
            {
                c.Id,
                c.CellCount,
                c.AreaM2,
                c.CreatedAt,
            })
            .ToListAsync();

        return Ok(claims);
    }

    /// <summary>
    /// Returns the FULL game state for a user in a single call:
    /// profile + XP + missions + achievements + exploration + rank.
    /// The mobile app calls this once on load and after every walk capture
    /// instead of 7 separate API calls.
    /// </summary>
    [HttpGet("{id:guid}/game-state")]
    public async Task<IActionResult> GetGameState([FromRoute] Guid id, [FromQuery] string? localDate = null)
    {
        if (await DenySelf(id) is { } deny) return deny;

        var user = await _db.Users.FindAsync(id);
        if (user == null) return NotFound();

        // XP & Level
        var currentLevelXp = Constants.GameConstants.XpForLevel(user.Level);
        var nextLevelXp = Constants.GameConstants.XpForLevel(user.Level + 1);
        var progressXp = user.TotalXp - currentLevelXp;
        var neededXp = nextLevelXp - currentLevelXp;

        // Missions
        var missionService = HttpContext.RequestServices.GetRequiredService<IMissionService>();
        var missions = await missionService.GetTodaysMissions(id, GameDay.Resolve(localDate));

        // Achievements
        var achievementService = HttpContext.RequestServices.GetRequiredService<IAchievementService>();
        var achievements = await achievementService.GetAllForUser(id);

        // Exploration
        var territoryService = HttpContext.RequestServices.GetRequiredService<ITerritoryService>();
        var exploration = await territoryService.GetExplorationStats(id, 0, 0);

        // Rank (city leaderboard)
        int rank = 0;
        try
        {
            var leaderboard = await _db.Users
                .Where(u => u.City == user.City && !string.IsNullOrEmpty(u.City))
                .OrderByDescending(u => u.HexCount)
                .Select(u => u.Id)
                .ToListAsync();
            rank = leaderboard.IndexOf(id) + 1;
        }
        catch (Exception ex)
        {
            // Rank is a non-critical adornment on the game-state payload; degrade to 0 rather
            // than fail the whole call, but record it so a recurring failure is visible.
            _logger.LogWarning(ex, "Rank computation failed for {UserId}; returning rank 0", id);
        }

        return Ok(new
        {
            // Profile
            user.Id,
            user.DisplayName,
            user.Color,
            user.AvatarId,
            user.HexCount,
            user.TotalHexesCaptured,
            user.TotalHexesStolen,
            user.Streak,
            user.IsStreakActive,
            user.DistanceKm,
            Rank = rank,

            // XP
            Xp = new
            {
                user.TotalXp,
                user.Level,
                ProgressXp = progressXp,
                NeededXp = neededXp,
                ProgressPercent = neededXp > 0 ? Math.Round(progressXp * 100.0 / neededXp, 1) : 100.0,
            },

            // Daily Missions
            Missions = missions.Select(m => new
            {
                m.Id,
                m.Type,
                m.Description,
                m.TargetValue,
                m.CurrentProgress,
                m.XpReward,
                m.IsCompleted,
                m.CompletedAt,
            }),

            // Achievements
            Achievements = achievements,

            // Exploration
            Exploration = exploration,
        });
    }
}
