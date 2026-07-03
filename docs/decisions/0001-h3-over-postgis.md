# ADR-0001: Use Uber H3 as the canonical spatial grid, not PostGIS

- **Status:** Accepted
- **Date:** 2026-06-11
- **Deciders:** Engineering

## Context

The game needs to: divide the entire planet into uniform, claimable units; compute which
units fall inside a walked loop (point-in-polygon fill); cluster nearby units for real-time
broadcast and city-level queries; and do all of this cheaply at scale. The two realistic
approaches were PostGIS geometry columns with GiST indexes, or a discrete global grid (H3).

## Decision

Use **Uber H3 at resolution 10** as the canonical cell grid. Store ownership keyed by the
64-bit H3 index. Do **not** adopt PostGIS geometry columns or GiST indexes; use precomputed
H3 parent IDs (`ParentCellId` res-3, `NeighborhoodId` res-8) as spatial buckets, plus
`CenterLat`/`CenterLng` range scans for arbitrary viewports.

> **Amendment (2026-07):** the canonical cell resolution has since moved from 10 to **11**
> (~2,150 m²/cell); the parent buckets (res-3 / res-8) and the H3-over-PostGIS decision itself
> are unchanged. See [spatial-model.md](../architecture/spatial-model.md).

## Consequences

- **Positive:** Uniform global hexagons with no projection distortion. Built-in polygon fill
  and a parent hierarchy that doubles as a free spatial index and as SignalR region-group
  keys. No PostGIS extension to operate, version, or scale.
- **Negative / Trade-offs:** Geometry is stored as JSON strings (`BoundaryJson`,
  `PolygonJson`) for rendering, which cannot be queried spatially in SQL. Arbitrary-radius
  geo queries are less ergonomic than `ST_DWithin`; we model "nearby" via H3 rings/buckets
  instead.
- **Follow-ups:** Add indexes on `(ParentCellId, OwnerId)`, `(NeighborhoodId)`,
  `(CenterLat, CenterLng)`. **Correct the root README's "PostGIS GiST spatial index" claim**
  — it does not reflect the implementation. See
  [spatial-model.md](../architecture/spatial-model.md).

## Alternatives Considered

| Option | Why rejected |
|--------|--------------|
| PostGIS geometry + GiST | Heavier to operate; H3 already provides hierarchy, fill, and uniform cells. Adds an extension dependency for no net gain in this game model. |
| Raw lat/lng grid (custom squares) | Projection distortion; no standard libraries; reinvents H3 poorly. |
