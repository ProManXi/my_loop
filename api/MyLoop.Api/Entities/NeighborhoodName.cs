namespace MyLoop.Api.Entities;

/// <summary>
/// Persisted reverse-geocode result for an H3 res-8 neighborhood, keyed by the neighborhood
/// itself (not by user) so every user who ever explores the same area reuses one Nominatim
/// lookup forever. See #121 / ML-ERR-024 — <see cref="Services.TerritoryService.GetExplorationStats"/>
/// used to await Nominatim inline on the `/game-state` hot path; this table lets it return
/// immediately from persisted state while resolution happens in the background.
/// </summary>
public class NeighborhoodName
{
    /// <summary>H3 cell ID of the neighborhood (res 8) — primary key.</summary>
    public long NeighborhoodId { get; set; }

    public string AreaName { get; set; } = "";

    public DateTime ResolvedAt { get; set; }
}
