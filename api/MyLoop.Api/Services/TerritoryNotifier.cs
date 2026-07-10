using Microsoft.AspNetCore.SignalR;
using MyLoop.Api.Hubs;
using MyLoop.Api.Interfaces;

namespace MyLoop.Api.Services;

/// <summary>
/// Broadcasts hex ownership changes (public, region-scoped) and personal
/// state deltas (per-user group) via SignalR.
/// </summary>
public class TerritoryNotifier : ITerritoryNotifier
{
    private readonly IHubContext<TerritoryHub> _hubContext;
    private readonly ILogger<TerritoryNotifier> _logger;

    public TerritoryNotifier(IHubContext<TerritoryHub> hubContext, ILogger<TerritoryNotifier> logger)
    {
        _hubContext = hubContext;
        _logger = logger;
    }

    public async Task NotifyHexOwnershipChanged(IReadOnlyList<HexChangeEvent> changes)
    {
        if (changes.Count == 0) return;

        // Group changes by parent cell (region) for targeted broadcast
        var byRegion = changes.GroupBy(c => c.ParentCellId.ToString());

        var regionCount = 0;
        foreach (var regionGroup in byRegion)
        {
            var payload = regionGroup.Select(c => new
            {
                c.H3Index,
                c.CenterLat,
                c.CenterLng,
                c.NewOwnerId,
                c.NewOwnerColor,
                c.NewOwnerDisplayName,
                c.PreviousOwnerId,
            }).ToList();

            // Isolate each region: a transient transport failure on one group
            // must not abort delivery to the others (HIGH-10). These broadcasts
            // are fire-and-forget, so a thrown exception would also go unobserved.
            try
            {
                await _hubContext.Clients
                    .Group(regionGroup.Key)
                    .SendAsync("HexOwnershipChanged", payload);
                regionCount++;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex,
                    "Failed to broadcast HexOwnershipChanged to region {Region}", regionGroup.Key);
            }
        }

        _logger.LogDebug("Broadcast {Count} hex changes to {RegionCount} regions",
            changes.Count, regionCount);
    }

    public async Task NotifyHexesReleasedAsync(IReadOnlyList<HexReleasedEvent> released)
    {
        if (released.Count == 0) return;

        foreach (var regionGroup in released.GroupBy(r => r.ParentCellId.ToString()))
        {
            var payload = new
            {
                ParentCellId = regionGroup.Key,
                H3Indexes = regionGroup.Select(r => r.H3Index).ToList(),
            };

            // Same per-region isolation as HexOwnershipChanged (HIGH-10): one group's
            // transport failure must not abort delivery to the others.
            try
            {
                await _hubContext.Clients
                    .Group(regionGroup.Key)
                    .SendAsync("HexesReleased", payload);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex,
                    "Failed to broadcast HexesReleased to region {Region}", regionGroup.Key);
            }
        }
    }

    public Task NotifyUserStatsAsync(Guid userId, UserStatsDelta delta) =>
        SafeSendToUser(userId, "UserStatsDelta", delta, "UserStatsDelta");

    public Task NotifyXpAsync(Guid userId, XpDelta delta) =>
        SafeSendToUser(userId, "XpDelta", delta, "XpDelta");

    public Task NotifyMissionAsync(Guid userId, MissionDelta delta) =>
        delta.Updates.Count == 0
            ? Task.CompletedTask
            : SafeSendToUser(userId, "MissionDelta", delta, "MissionDelta");

    public Task NotifyAchievementAsync(Guid userId, AchievementDelta delta) =>
        delta.Unlocks.Count == 0
            ? Task.CompletedTask
            : SafeSendToUser(userId, "AchievementUnlocked", delta, "AchievementUnlocked");

    /// <summary>
    /// Sends a personal delta to the user's group, swallowing (but logging) transport
    /// failures so a dropped connection never surfaces as an unobserved task exception
    /// in the fire-and-forget push path (HIGH-10).
    /// </summary>
    private async Task SafeSendToUser<T>(Guid userId, string method, T payload, string label)
    {
        try
        {
            await _hubContext.Clients.Group($"user_{userId}").SendAsync(method, payload);
            _logger.LogDebug("Pushed {Label} to user {UserId}", label, userId);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to push {Label} to user {UserId}", label, userId);
        }
    }
}
