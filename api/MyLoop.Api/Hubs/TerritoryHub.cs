using System.Security.Claims;
using Microsoft.AspNetCore.SignalR;
using MyLoop.Api.Interfaces;

namespace MyLoop.Api.Hubs;

/// <summary>
/// SignalR hub for real-time territory updates.
/// Clients join geographic region groups (H3 resolution-3 parent cells)
/// for public map updates, and a personal user group for private state deltas.
/// Connection does NOT require auth (public map events work without login).
/// Personal group methods validate auth via Context.User claim.
/// </summary>
public class TerritoryHub : Hub
{
    private readonly IUserService _users;
    private readonly IHexGridService _hexGrid;
    private readonly ILogger<TerritoryHub> _logger;

    public TerritoryHub(IUserService users, IHexGridService hexGrid, ILogger<TerritoryHub> logger)
    {
        _users = users;
        _hexGrid = hexGrid;
        _logger = logger;
    }

    public override Task OnConnectedAsync()
    {
        _logger.LogDebug("Hub connected: {ConnectionId} (authenticated: {IsAuth})",
            Context.ConnectionId, Context.User?.Identity?.IsAuthenticated == true);
        return base.OnConnectedAsync();
    }

    public override Task OnDisconnectedAsync(Exception? exception)
    {
        if (exception != null)
            _logger.LogWarning(exception, "Hub disconnected with error: {ConnectionId}", Context.ConnectionId);
        else
            _logger.LogDebug("Hub disconnected: {ConnectionId}", Context.ConnectionId);
        return base.OnDisconnectedAsync(exception);
    }

    /// <summary>
    /// Client calls this to subscribe to a geographic region (public map events).
    /// Region ID = H3 res-3 parent cell ID (covers ~12,000 km²).
    /// </summary>
    public async Task JoinRegion(string regionId)
    {
        // regionId is caller-supplied. Region groups are named by a res-3 H3 cell id, but personal
        // delta groups are named "user_{guid}" (see TerritoryNotifier). Without this check a caller
        // could pass any string — including another user's "user_{guid}" — and receive that user's
        // private stat/XP/mission deltas. Constrain the group name to a genuine region id so only
        // real, public map regions can be joined.
        if (!_hexGrid.IsValidRegionId(regionId))
        {
            _logger.LogWarning("Rejected JoinRegion with non-region id {RegionId} on {ConnectionId}",
                regionId, Context.ConnectionId);
            throw new HubException("Invalid region id.");
        }

        await Groups.AddToGroupAsync(Context.ConnectionId, regionId);
    }

    /// <summary>
    /// Client calls this to unsubscribe from a region (e.g., when panning away).
    /// </summary>
    public async Task LeaveRegion(string regionId)
    {
        await Groups.RemoveFromGroupAsync(Context.ConnectionId, regionId);
    }

    /// <summary>
    /// Client calls this after auth to subscribe to personal state deltas.
    /// Group name: "user_{userId}" where userId is the caller's INTERNAL DB Guid
    /// (the same id the server pushes deltas to — see TerritoryNotifier).
    /// Validates caller is authenticated (token passed via query string on connect)
    /// AND that the requested group is their own.
    /// </summary>
    public async Task JoinUserGroup(string userId)
    {
        // Only authenticated connections can join personal groups
        if (Context.User?.Identity?.IsAuthenticated != true)
        {
            _logger.LogWarning("Unauthenticated personal-group join rejected for user_{UserId} on {ConnectionId}",
                userId, Context.ConnectionId);
            throw new HubException("Authentication required for personal group subscription.");
        }

        // A caller may only join THEIR OWN personal group, else any authenticated user
        // could subscribe to another user's private deltas (stats, XP, missions,
        // achievements). The JWT carries the Firebase UID, but the group is keyed by the
        // INTERNAL Guid, so we must map UID -> internal id (same mapping the REST layer
        // uses, CurrentUser.cs) before comparing — comparing the raw UID claim against the
        // Guid arg would reject every legitimate join.
        var firebaseUid = Context.User.FindFirst(Constants.FirebaseClaims.UserId)?.Value
            ?? Context.User.FindFirst(Constants.FirebaseClaims.Subject)?.Value
            ?? Context.User.FindFirst(ClaimTypes.NameIdentifier)?.Value;

        if (string.IsNullOrEmpty(firebaseUid))
            throw new HubException("Authentication required for personal group subscription.");

        var caller = await _users.GetByFirebaseUid(firebaseUid);
        if (caller is null
            || !Guid.TryParse(userId, out var requestedId)
            || caller.Id != requestedId)
        {
            _logger.LogWarning("Cross-user personal-group join rejected: caller uid {Uid} tried to join user_{UserId}",
                firebaseUid, userId);
            throw new HubException("Cannot subscribe to another user's personal group.");
        }

        await Groups.AddToGroupAsync(Context.ConnectionId, $"user_{userId}");
    }

    /// <summary>
    /// Client calls this to leave personal group (e.g., on logout).
    /// </summary>
    public async Task LeaveUserGroup(string userId)
    {
        await Groups.RemoveFromGroupAsync(Context.ConnectionId, $"user_{userId}");
    }
}
