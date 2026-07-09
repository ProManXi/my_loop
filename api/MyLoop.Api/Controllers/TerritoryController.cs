using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using MyLoop.Api.Interfaces;

namespace MyLoop.Api.Controllers;

/// <summary>
/// Handles territory queries — viewport cells, per-user territories, stolen cells,
/// claim history, and exploration progress.
/// Endpoints that expose a player's PRIVATE data (stolen cells, walk history,
/// exploration progress) are restricted to the authenticated owner. Public map
/// data remains readable by any authenticated user.
/// </summary>
[ApiController]
[Route("api/territories")]
[Authorize]
public class TerritoryController : ControllerBase
{
    private readonly ITerritoryService _territoryService;
    private readonly ICurrentUser _currentUser;
    private readonly ILogger<TerritoryController> _logger;

    public TerritoryController(ITerritoryService territoryService, ICurrentUser currentUser,
        ILogger<TerritoryController> logger)
    {
        _territoryService = territoryService;
        _currentUser = currentUser;
        _logger = logger;
    }

    /// <summary>
    /// Get all territory cells within a map viewport bounding box (public map data).
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> GetTerritoriesInViewport(
        [FromQuery] double minLat,
        [FromQuery] double minLng,
        [FromQuery] double maxLat,
        [FromQuery] double maxLng)
    {
        var viewport = await _territoryService.GetTerritoriesInViewport(minLat, minLng, maxLat, maxLng);
        // The body stays the bare cell array the mobile client already parses; truncation is
        // additive metadata in a header so existing clients are unaffected (#114).
        Response.Headers["X-Viewport-Truncated"] = viewport.Truncated ? "true" : "false";
        return Ok(viewport.Cells);
    }

    /// <summary>
    /// Get hexes that were stolen from this user within N days (private — revenge list).
    /// </summary>
    [HttpGet("stolen/{userId:guid}")]
    public async Task<IActionResult> GetStolenCells(
        [FromRoute] Guid userId,
        [FromQuery] int days = 7)
    {
        if (await DenySelf(userId) is { } deny) return deny;

        var result = await _territoryService.GetStolenCells(userId, days);
        return Ok(result);
    }

    /// <summary>
    /// Get ALL territory cells owned by a specific user (public — rendered on everyone's map).
    /// </summary>
    [HttpGet("user/{userId:guid}")]
    public async Task<IActionResult> GetUserTerritories([FromRoute] Guid userId)
    {
        var cells = await _territoryService.GetUserTerritories(userId);
        return Ok(cells);
    }

    /// <summary>
    /// Get a user's claim history — one entry per walk submission (private).
    /// </summary>
    [HttpGet("claims/{userId:guid}")]
    public async Task<IActionResult> GetClaimHistory([FromRoute] Guid userId)
    {
        if (await DenySelf(userId) is { } deny) return deny;

        var history = await _territoryService.GetClaimHistory(userId);
        return Ok(history);
    }

    /// <summary>
    /// Get exploration stats for neighborhoods near a GPS point (private progress).
    /// </summary>
    [HttpGet("exploration/{userId:guid}")]
    public async Task<IActionResult> GetExplorationStats(
        [FromRoute] Guid userId,
        [FromQuery] double lat,
        [FromQuery] double lng)
    {
        if (await DenySelf(userId) is { } deny) return deny;

        var stats = await _territoryService.GetExplorationStats(userId, lat, lng);
        return Ok(stats);
    }

    /// <summary>
    /// Returns Unauthorized/Forbid if the caller is not the user named in the route;
    /// null when the caller is the owner and the request may proceed.
    /// </summary>
    private async Task<IActionResult?> DenySelf(Guid routeUserId)
    {
        var callerId = await _currentUser.TryGetUserIdAsync();
        if (callerId is null) return Unauthorized();
        if (routeUserId != callerId)
        {
            _logger.LogWarning("Cross-user access denied: caller {CallerId} requested private territory data for {RouteUserId}",
                callerId, routeUserId);
            return Forbid();
        }
        return null;
    }
}
