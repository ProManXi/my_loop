using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Services;

namespace MyLoop.Api.Controllers;

/// <summary>
/// A caller may only read their OWN achievements — the acting user is resolved from the
/// Firebase JWT via <see cref="ICurrentUser"/>, and any mismatch with the route id is rejected.
/// </summary>
[ApiController]
[Authorize]
[Route("api/achievements")]
public class AchievementsController : ControllerBase
{
    private readonly IAchievementService _achievementService;
    private readonly ICurrentUser _currentUser;
    private readonly ILogger<AchievementsController> _logger;

    public AchievementsController(IAchievementService achievementService, ICurrentUser currentUser,
        ILogger<AchievementsController> logger)
    {
        _achievementService = achievementService;
        _currentUser = currentUser;
        _logger = logger;
    }

    /// <summary>Get all achievements with user's progress and unlock status.</summary>
    [HttpGet("{userId:guid}")]
    public async Task<IActionResult> GetAchievements([FromRoute] Guid userId)
    {
        var callerId = await _currentUser.TryGetUserIdAsync();
        if (callerId is null) return Unauthorized();
        if (userId != callerId)
        {
            _logger.LogWarning("Cross-user access denied: caller {CallerId} requested achievements for {RouteUserId}",
                callerId, userId);
            return Forbid();
        }

        _logger.LogInformation("Fetching achievements for user {UserId}", userId);
        var achievements = await _achievementService.GetAllForUser(userId);
        return Ok(achievements);
    }
}
