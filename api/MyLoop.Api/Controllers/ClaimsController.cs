using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using MyLoop.Api.Constants;
using MyLoop.Api.Interfaces;
using MyLoop.Api.Models;

namespace MyLoop.Api.Controllers;

/// <summary>
/// Handles territory claim submission. The acting user is ALWAYS the authenticated
/// caller (resolved from the Firebase JWT via <see cref="ICurrentUser"/>); any UserId
/// present in a request body is ignored.
/// </summary>
[ApiController]
[Route("api/claims")]
[Authorize]
public class ClaimsController : ControllerBase
{
    private readonly ITerritoryService _territoryService;
    private readonly IHexGridService _hexGridService;
    private readonly ICurrentUser _currentUser;
    private readonly IPathValidationService _pathValidation;
    private readonly ILogger<ClaimsController> _logger;

    public ClaimsController(
        ITerritoryService territoryService,
        IHexGridService hexGridService,
        ICurrentUser currentUser,
        IPathValidationService pathValidation,
        ILogger<ClaimsController> logger)
    {
        _territoryService = territoryService;
        _hexGridService = hexGridService;
        _currentUser = currentUser;
        _pathValidation = pathValidation;
        _logger = logger;
    }

    /// <summary>
    /// Submit a territory claim. The user walked a path — we compute
    /// which hexes they captured and assign ownership.
    /// </summary>
    [HttpPost]
    public async Task<IActionResult> SubmitClaim([FromBody] ClaimRequest request)
    {
        var callerId = await _currentUser.TryGetUserIdAsync();
        if (callerId is null) return Unauthorized();

        if (request.Path.Length > GameConstants.MaxClaimPathPoints)
            return BadRequest("Path too long");
        if (!ValidatePathCoordinates(request.Path))
            return BadRequest("Invalid GPS coordinates in path");

        try
        {
            var result = await _territoryService.ProcessClaim(
                callerId.Value, request.Path, ParseWalkSessionId(request.WalkSessionId), request.LocalDate);

            if (!result.Success)
                return BadRequest(new { error = result.Error });

            return Created($"/api/claims/{result.Data!.Id}", result.Data);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Claim processing failed for user {UserId}", callerId);
            return StatusCode(500, new { error = "Claim processing failed. Please try again." });
        }
    }

    /// <summary>
    /// Batch step claim. Receives N GPS points captured during a walk
    /// (drained from the client's persistent write-ahead log) and processes
    /// them atomically.
    /// </summary>
    [HttpPost("batch-step")]
    public async Task<IActionResult> ClaimBatchStep([FromBody] BatchStepClaimRequest request)
    {
        var callerId = await _currentUser.TryGetUserIdAsync();
        if (callerId is null) return Unauthorized();

        if (request?.Points == null || request.Points.Count == 0)
            return BadRequest("No points provided");

        if (request.Points.Count > 200)
            return BadRequest("Too many points in a single batch (max 200)");

        foreach (var p in request.Points)
        {
            if (p.Lat < -90 || p.Lat > 90 || p.Lng < -180 || p.Lng > 180)
                return BadRequest("Invalid coordinates in batch");
            if (double.IsNaN(p.Lat) || double.IsNaN(p.Lng) ||
                double.IsInfinity(p.Lat) || double.IsInfinity(p.Lng))
                return BadRequest("Invalid coordinates in batch");
        }

        // Anti-cheat: reject batches whose consecutive points imply impossible speed
        // (teleport / GPS spoofing). Mirrors the validation already applied to loop claims.
        var speedError = _pathValidation.ValidateConsecutivePoints(
            request.Points.Select(p => (p.Lat, p.Lng, p.CapturedAt)).ToList());
        if (speedError != null)
        {
            _logger.LogWarning("Batch-step rejected for user {UserId}: {Reason}", callerId, speedError);
            return BadRequest(new { error = $"Anti-cheat: {speedError}" });
        }

        // Anti-cheat: reject batches whose bearing changes are unnaturally smooth (synthetic
        // straight-line / regular spoof paths). The loop-claim path already applies this gate;
        // the live batch-step path skipped it (#52). Short batches are tolerated by the gate.
        var smoothnessError = _pathValidation.ValidateSmoothness(
            request.Points.Select(p => (p.Lat, p.Lng)).ToList());
        if (smoothnessError != null)
        {
            _logger.LogWarning("Batch-step rejected for user {UserId}: {Reason}", callerId, smoothnessError);
            return BadRequest(new { error = $"Anti-cheat: {smoothnessError}" });
        }

        try
        {
            var result = await _territoryService.ProcessBatchStepClaim(
                callerId.Value, request.LocalDate, request.Points, ParseWalkSessionId(request.WalkSessionId));
            return Ok(result);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Batch step claim failed for user {UserId}", callerId);
            return StatusCode(500, new { error = "Batch step claim failed." });
        }
    }

    /// <summary>
    /// Preview which hexes a path would capture — no DB writes.
    /// </summary>
    [HttpPost("preview")]
    public IActionResult PreviewClaim([FromBody] PreviewRequest request)
    {
        if (request.Path.Length < GameConstants.MinPointsForPolygon)
            return Ok(new { boundaries = Array.Empty<double[][]>(), loopCount = 0 });

        if (request.Path.Length > GameConstants.MaxPreviewPathLength)
            return BadRequest("Path too long for preview");

        if (!ValidatePathCoordinates(request.Path))
            return Ok(new { boundaries = Array.Empty<double[][]>(), loopCount = 0 });

        try
        {
            var territory = _hexGridService.ComputeCapturedTerritory(request.Path);
            var boundaries = territory.Cells.Select(c => c.Boundary).ToArray();
            // loopCount is the authoritative, area-validated/de-duplicated count
            // the app should show, replacing the client's raw closure count (#21).
            return Ok(new { boundaries, loopCount = territory.LoopCount });
        }
        catch (Exception)
        {
            return Ok(new { boundaries = Array.Empty<double[][]>(), loopCount = 0 });
        }
    }

    private static bool ValidatePathCoordinates(double[][] path)
    {
        foreach (var point in path)
        {
            if (point.Length < 2) return false;
            if (point[0] < -90 || point[0] > 90) return false;
            if (point[1] < -180 || point[1] > 180) return false;
            if (double.IsNaN(point[0]) || double.IsNaN(point[1])) return false;
            if (double.IsInfinity(point[0]) || double.IsInfinity(point[1])) return false;
        }
        return true;
    }

    /// <summary>
    /// Parses the client-supplied walk session id. The client sends a UUID string; an absent,
    /// empty, or unparseable value resolves to <see cref="Guid.Empty"/>, which the service treats
    /// as a standalone claim. Parsing here (instead of a non-nullable Guid DTO) keeps a malformed
    /// id from 400-ing the core claim path at model binding (#56).
    /// </summary>
    private static Guid ParseWalkSessionId(string? walkSessionId) =>
        Guid.TryParse(walkSessionId, out var id) ? id : Guid.Empty;
}
