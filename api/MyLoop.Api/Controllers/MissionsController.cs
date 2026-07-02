using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MyLoop.Api.Data;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Services;

namespace MyLoop.Api.Controllers;

/// <summary>
/// Daily-mission and XP read endpoints. A caller may only read their OWN
/// missions/XP — the acting user is resolved from the Firebase JWT via
/// <see cref="ICurrentUser"/>, and any mismatch with the route id is rejected.
/// </summary>
[ApiController]
[Route("api/missions")]
[Authorize]
public class MissionsController : ControllerBase
{
    private readonly IMissionService _missionService;
    private readonly AppDbContext _db;
    private readonly ICurrentUser _currentUser;
    private readonly ILogger<MissionsController> _logger;

    public MissionsController(IMissionService missionService, AppDbContext db, ICurrentUser currentUser,
        ILogger<MissionsController> logger)
    {
        _missionService = missionService;
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
            _logger.LogWarning("Cross-user access denied: caller {CallerId} requested missions/XP for {RouteUserId}",
                callerId, routeUserId);
            return Forbid();
        }
        return null;
    }

    /// <summary>Get today's daily missions for a user (generates them if not yet created).</summary>
    [HttpGet("{userId:guid}")]
    public async Task<IActionResult> GetMissions([FromRoute] Guid userId, [FromQuery] string? localDate = null)
    {
        if (await DenySelf(userId) is { } deny) return deny;

        // Resolve today's missions against the player's LOCAL day so they don't reset mid-day for
        // players far from UTC (matches streaks and the claim paths).
        var missions = await _missionService.GetTodaysMissions(userId, GameDay.Resolve(localDate));
        return Ok(missions.Select(m => new
        {
            m.Id,
            m.Type,
            m.Description,
            m.TargetValue,
            m.CurrentProgress,
            m.XpReward,
            m.IsCompleted,
            m.CompletedAt,
        }));
    }

    /// <summary>Get user's XP and level info.</summary>
    [HttpGet("xp/{userId:guid}")]
    public async Task<IActionResult> GetXpInfo([FromRoute] Guid userId)
    {
        if (await DenySelf(userId) is { } deny) return deny;

        var user = await _db.Users.FindAsync(userId);
        if (user == null) return NotFound();

        var currentLevelXp = MyLoop.Api.Constants.GameConstants.XpForLevel(user.Level);
        var nextLevelXp = MyLoop.Api.Constants.GameConstants.XpForLevel(user.Level + 1);
        var progressXp = user.TotalXp - currentLevelXp;
        var neededXp = nextLevelXp - currentLevelXp;

        return Ok(new
        {
            user.TotalXp,
            user.Level,
            ProgressXp = progressXp,
            NeededXp = neededXp,
            ProgressPercent = neededXp > 0 ? Math.Round(progressXp * 100.0 / neededXp, 1) : 100.0,
        });
    }


}
