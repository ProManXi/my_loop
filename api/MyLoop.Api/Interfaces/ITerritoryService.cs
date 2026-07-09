using MyLoop.Api.Models;

namespace MyLoop.Api.Interfaces;

/// <summary>
/// Territory operations — claim processing, territory queries, stolen cells.
/// </summary>
public interface ITerritoryService
{
    /// <summary>
    /// Processes a territory claim: validates the path, computes hex cells,
    /// assigns ownership, and records transfers.
    /// Returns the claim result or an error message.
    /// </summary>
    Task<ClaimResult> ProcessClaim(Guid userId, double[][] path, Guid walkSessionId, string? clientLocalDate = null);

    /// <summary>
    /// Batch step claim: processes N GPS points atomically in a single transaction.
    /// Reliable replacement for per-tick step claims — survives flaky networks.
    /// Pre-loads existing cells once, applies all changes, single SaveChangesAsync,
    /// single consolidated push (final state, not per-point deltas).
    /// </summary>
    Task<BatchStepClaimResponse> ProcessBatchStepClaim(
        Guid userId, string? clientLocalDate, List<BatchStepPoint> points, Guid walkSessionId);

    /// <summary>
    /// Gets the territory cells within a map viewport bounding box (deterministically
    /// ordered, capped) plus whether the cap truncated the result.
    /// </summary>
    Task<TerritoryViewportResult> GetTerritoriesInViewport(
        double minLat, double minLng, double maxLat, double maxLng);

    /// <summary>
    /// Gets a user's total territory stats (cell count + area).
    /// </summary>
    Task<TerritoryStatsResponse> GetUserStats(Guid userId);

    /// <summary>
    /// Gets hexes stolen from a user within the given number of days.
    /// </summary>
    Task<StolenCellsResponse> GetStolenCells(Guid userId, int days);

    /// <summary>
    /// Gets the ownership history of a specific hex cell.
    /// </summary>
    Task<CellHistoryResponse> GetCellHistory(long cellId);

    /// <summary>
    /// Gets ALL territory cells owned by a specific user (regardless of viewport).
    /// </summary>
    Task<List<TerritoryCellResponse>> GetUserTerritories(Guid userId);

    /// <summary>
    /// Gets exploration stats: for each neighborhood near the user,
    /// returns the number of cells explored vs total cells in that neighborhood.
    /// </summary>
    Task<List<ExplorationNeighborhood>> GetExplorationStats(Guid userId, double lat, double lng);

    /// <summary>
    /// Gets a user's claim history — one entry per claim submission.
    /// </summary>
    Task<List<ClaimHistoryEntry>> GetClaimHistory(Guid userId);
}

/// <summary>
/// Result of a claim operation — either success (with data) or failure (with error).
/// </summary>
public class ClaimResult
{
    public bool Success { get; private init; }
    public string? Error { get; private init; }
    public ClaimResponse? Data { get; private init; }

    public static ClaimResult Failure(string error) => new() { Success = false, Error = error };
    public static ClaimResult Succeeded(ClaimResponse data) => new() { Success = true, Data = data };
}
