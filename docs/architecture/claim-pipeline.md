# Claim Pipeline

The core loop: a walked GPS path becomes owned territory. Implemented across
`PathValidationService` (anti-cheat), `HexGridService` (H3 math), `TerritoryService`
(ownership), and `TerritoryNotifier` / `PushNotificationService` (broadcast).

```
GPS Path (200m+ walk, ≥10 points)
    │
    ▼
┌─ Anti-Cheat Validation (PathValidationService) ──────────┐
│  • Speed:      ≤30 km/h between consecutive points        │
│  • Duration:   ≥50% of expected GPS samples for distance  │
│  • Smoothness: bearing σ > 2° (rejects linear spoofing)   │
└───────────────────────────────────────────────────────────┘
    │
    ▼
┌─ H3 Hex Computation (HexGridService) ────────────────────┐
│  1. Trail cells: hexes the path crosses                   │
│  2. Loop detection: endpoints ≤50 m apart                 │
│  3. Polygon fill: interior via NetTopologySuite geometry  │
│  4. Dedup: skip cells with >80% overlap                   │
└───────────────────────────────────────────────────────────┘
    │
    ▼
┌─ Ownership Assignment (single DB transaction) ───────────┐
│  • Skip cells on cooldown (steal-back protection window)  │
│  • Skip self-owned cells                                  │
│  • Steal from others → write a CellTransfer row           │
│  • Update owner stats (hex count, streak, distance)       │
└───────────────────────────────────────────────────────────┘
    │
    ▼
┌─ Post-Commit Broadcast ──────────────────────────────────┐
│  • SignalR → nearby clients (map update)                  │
│  • FCM → victims ("Territory Under Attack!")              │
└───────────────────────────────────────────────────────────┘
```

## Anti-cheat thresholds

| Check | Method | Threshold | Tolerance |
|-------|--------|-----------|-----------|
| Speed | Haversine between consecutive points | 60 m per 5 s (30 km/h) | 5% violation rate allowed |
| Duration | Point count vs expected for distance | ≥50% of expected samples | — |
| Smoothness | Std dev of bearing changes | > 2° required | Rejects linear spoofed paths |

## Invariants

- A claim is **immutable** once written (`Claim` entity). Ownership changes are tracked
  separately on `TerritoryCell` and in the append-only `CellTransfer` log.
- **Every steal must write a `CellTransfer`.** Downstream features (revenge, rivalries,
  seasons, "most contested hex") depend on this event trail — never skip it to save a write.
- Ownership assignment happens in **one DB transaction** so the map can't observe a
  half-applied claim.
