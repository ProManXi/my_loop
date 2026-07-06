namespace MyLoop.Api.Entities;

using System.Text.Json;

/// <summary>
/// Represents a single hexagonal territory cell on the game map.
/// Each cell corresponds to one H3 hexagon at <see cref="Constants.GameConstants.H3Resolution"/>
/// (res-11: ~29 m edge, ~2,150 m² area — see <see cref="Constants.GameConstants.CellAreaSquareMeters"/>).
/// The <see cref="CellId"/> is a 64-bit H3 index that uniquely identifies a hexagon on Earth.
/// Ownership follows a "last-writer-wins" model — whoever claims it most recently owns it.
/// </summary>
public class TerritoryCell
{
    /// <summary>H3 index (64-bit integer) — the globally unique identifier of this hexagon on the planet. Used as the primary key.</summary>
    public long CellId { get; set; }

    /// <summary>The user who currently owns this cell. Updated on each claim that covers this hex.</summary>
    public Guid OwnerId { get; set; }

    /// <summary>The claim that most recently captured this cell.</summary>
    public Guid ClaimId { get; set; }

    /// <summary>Timestamp when this cell was last claimed/stolen.</summary>
    public DateTime ClaimedAt { get; set; }

    /// <summary>UTC time when the cooldown expires and the cell becomes stealable again.</summary>
    public DateTime? CooldownExpiresAt { get; set; }

    /// <summary>Latitude of the hexagon's center point. Used for spatial viewport queries with indexed range scans.</summary>
    public double CenterLat { get; set; }

    /// <summary>Longitude of the hexagon's center point. Used for spatial viewport queries with indexed range scans.</summary>
    public double CenterLng { get; set; }

    /// <summary>
    /// H3 parent cell ID at resolution 3 — acts as a spatial hash bucket.
    /// Cells sharing the same parent are geographically clustered (~12km zones).
    /// Extensibility hook for geohash-style partition pruning and city-level queries.
    /// </summary>
    public long ParentCellId { get; set; }

    /// <summary>
    /// H3 parent cell ID at resolution 8 — the neighborhood bucket (~700m).
    /// Used for per-area ownership counts in the exploration feature.
    /// </summary>
    public long NeighborhoodId { get; set; }

    /// <summary>
    /// Last time the owner physically visited (walked through) this cell.
    /// Used for decay: cells not refreshed within DecayDays lose ownership.
    /// Set on initial claim and updated when owner walks through again.
    /// </summary>
    public DateTime LastRefreshedAt { get; set; }

    /// <summary>
    /// How many days this cell survives without a refresh before decaying.
    /// Calculated at capture time based on distance from owner's home location.
    /// Local (same city): 7d, Other city: 15d, Other region: 30d, Other country: 60d, Other continent: 90d.
    /// </summary>
    public int DecayDays { get; set; } = 7;

    /// <summary>
    /// The 6 (or 5) corner vertices of this hexagon, serialized as a JSON array of [lat, lng] pairs.
    /// Used by the mobile client to render the hex polygon on the map.
    /// </summary>
    public string BoundaryJson { get; set; } = "[]";

    /// <summary>
    /// Deserializes the stored boundary JSON back into a coordinate array.
    /// </summary>
    /// <returns>Array of [latitude, longitude] pairs representing the hex vertices.</returns>
    public double[][] GetBoundary() => JsonSerializer.Deserialize<double[][]>(BoundaryJson)!;

    /// <summary>
    /// Serializes a boundary coordinate array into JSON and stores it in <see cref="BoundaryJson"/>.
    /// </summary>
    /// <param name="boundary">Array of [latitude, longitude] pairs for the hex corners.</param>
    public void SetBoundary(double[][] boundary) => BoundaryJson = JsonSerializer.Serialize(boundary);

    /// <summary>Navigation property to the user who owns this cell.</summary>
    public User? Owner { get; set; }

    /// <summary>Navigation property to the claim that last captured this cell.</summary>
    public Claim? Claim { get; set; }
}
