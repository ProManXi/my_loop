# Spatial Model & Indexing

> **Correction to historical claims:** earlier docs/README described a "PostGIS GiST spatial
> index." **That is not what the code does.** The actual model is described here and is the
> source of truth. See [ADR-0001](../decisions/0001-h3-over-postgis.md).

## The grid

MyLoop uses **Uber H3 at resolution 11** as the canonical cell grid — global, uniform
hexagons of ~2,150 m² (~25 m edge). Each `TerritoryCell` is keyed by its 64-bit H3 index
(`CellId`), which uniquely identifies a hexagon on Earth.

H3 gives us, for free:
- A **global uniform grid** with no projection distortion problems.
- **Polygon fill** (`H3.Fill`) to compute the hexes inside a walked loop.
- A **hierarchy** of parent cells at coarser resolutions, which we use as spatial buckets.

## How spatial queries actually work

Geometry is **not** stored in a PostGIS geometry column. Instead:

- `CenterLat` / `CenterLng` (doubles) — the hex center, used for viewport range scans.
- `BoundaryJson` / `PolygonJson` — hex corners and walked path stored as **JSON strings**,
  used by the client to render polygons. Not queried spatially.
- `NetTopologySuite` is used **in-memory** in `HexGridService` for polygon fill, **not** for
  database spatial indexing.

### The real spatial-pruning mechanism: H3 parent buckets

`TerritoryCell` carries two precomputed H3 parent IDs that are the intended way to prune
queries at scale:

| Field | H3 res | Approx size | Use |
|-------|--------|-------------|-----|
| `CellId` | 11 | ~2,150 m² (~25 m edge) | The claimable cell itself; primary key of `TerritoryCell`. |
| `ParentCellId` | 3 | ~12,000 km² | City/region-scale bucket; SignalR region groups; partition pruning. |
| `NeighborhoodId` | 8 | ~0.74 km² | Per-area ownership counts (exploration feature). |

**Query rule:** viewport and "nearby" queries should filter **bucket-first**
(`ParentCellId` / `NeighborhoodId`), then refine by `CenterLat`/`CenterLng`. H3 *is* the
spatial index — we do not need PostGIS.

### Recommended indexes

- `(ParentCellId, OwnerId)` — viewport + per-owner queries within a region.
- `(NeighborhoodId)` — exploration counts.
- `(CenterLat, CenterLng)` — fallback range scans for arbitrary viewports.

## Decay & distance

`DecayDays` is computed at capture time from the distance between the cell and the owner's
home location (`HomeLat`/`HomeLng`): local 7d → other city 15d → region 30d → country 60d →
continent 90d. `DecayCleanupService` reclaims cells not refreshed within `DecayDays`.

> **Launch note:** decay is retention-punishing. Ship the MVP with decay disabled or set to
> a generous floor (e.g. 90d) until retention data exists.
