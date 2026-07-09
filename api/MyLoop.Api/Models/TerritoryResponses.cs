namespace MyLoop.Api.Models;

public class TerritoryCellResponse
{
    public long CellId { get; set; }
    public double[][]? Boundary { get; set; }
    public Guid OwnerId { get; set; }
    public string? OwnerColor { get; set; }
    public string? OwnerName { get; set; }
    public DateTime? CooldownExpiresAtUtc { get; set; }
    public long ParentCellId { get; set; }

    /// <summary>
    /// Decay progress from 0.0 (just refreshed) to 1.0 (about to expire).
    /// Client uses this to fade hex opacity, showing urgency to revisit.
    /// </summary>
    public double DecayProgress { get; set; }
}

public class TerritoryStatsResponse
{
    public int CellCount { get; set; }
    public double AreaM2 { get; set; }
}

public class StolenCellsResponse
{
    public int TotalStolen { get; set; }
    public DateTime Since { get; set; }
    public List<StealerSummary> ByStealer { get; set; } = [];
    public List<StolenCellDetail> Cells { get; set; } = [];
}

public class StealerSummary
{
    public Guid UserId { get; set; }
    public int CellsStolen { get; set; }
}

public class StolenCellDetail
{
    public long CellId { get; set; }
    public Guid ToUserId { get; set; }
    public DateTime TransferredAt { get; set; }
    public Guid ClaimId { get; set; }
}

public class CellHistoryResponse
{
    public long CellId { get; set; }
    public CellOwnerInfo? CurrentOwner { get; set; }
    public int TransferCount { get; set; }
    public List<CellTransferDetail> History { get; set; } = [];
}

public class CellOwnerInfo
{
    public Guid OwnerId { get; set; }
    public DateTime ClaimedAt { get; set; }
}

public class CellTransferDetail
{
    public Guid? FromUserId { get; set; }
    public Guid ToUserId { get; set; }
    public DateTime TransferredAt { get; set; }
    public Guid ClaimId { get; set; }
}

/// <summary>
/// Exploration stats for one neighborhood (H3 resolution 8 parent).
/// </summary>
public class ExplorationNeighborhood
{
    /// <summary>H3 cell ID of the neighborhood (res 8).</summary>
    public long NeighborhoodId { get; set; }

    /// <summary>Center lat of the neighborhood.</summary>
    public double CenterLat { get; set; }

    /// <summary>Center lng of the neighborhood.</summary>
    public double CenterLng { get; set; }

    /// <summary>Number of unique cells the user has explored in this neighborhood.</summary>
    public int ExploredCount { get; set; }

    /// <summary>Number of cells the user currently owns in this neighborhood.</summary>
    public int OwnedCount { get; set; }

    /// <summary>Total cells in this area (all players).</summary>
    public int TotalCount { get; set; }

    /// <summary>Exploration percentage (0.0 to 100.0).</summary>
    public double Percent { get; set; }

    /// <summary>Human-readable area/neighborhood name from reverse geocoding.</summary>
    public string AreaName { get; set; } = "";
}

/// <summary>
/// Service-level result for viewport queries. The HTTP body stays the bare cell array (the
/// mobile client parses a JSON list); Truncated travels as the X-Viewport-Truncated response
/// header so clients can adopt zoom-dependent handling (ML-FEAT-003) without a breaking change.
/// </summary>
public class TerritoryViewportResult
{
    public List<TerritoryCellResponse> Cells { get; set; } = [];

    /// <summary>True when the viewport held more cells than the response cap.</summary>
    public bool Truncated { get; set; }
}
