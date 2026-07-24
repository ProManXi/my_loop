/// Manages loading and state of hex territory cells on the map.
///
/// Handles viewport queries, user-owned hex loading, and state updates.
/// Extracted from _JourneyMapState to keep map widget focused on rendering.
library;

import 'package:myloop/shared/models/territory_cell.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/territory_cache.dart';
import 'package:myloop/shared/services/territory_realtime_service.dart';
import 'package:myloop/shared/constants/app_constants.dart';
import 'package:logging/logging.dart';

final _log = Logger('HexTerritory');

/// Single keyed entity store for every hex cell the map knows about.
///
/// Everything the map renders — the user's own hexes, other players' hexes,
/// cooldown markers — is a view derived on demand from one `Map<cellId,
/// TerritoryCell>`. All mutation is a keyed upsert or delete by `cellId`, the
/// stable identity SignalR events and API responses both carry. This
/// replaces an earlier design of several parallel/derived collections
/// (owned-hex boundaries and decay values as index-coupled lists, other
/// players' hexes keyed by color string with no cell identity) that could
/// silently desync, and that matched realtime removals by comparing
/// polygon-centroid floats — a false-positive risk between adjacent res-11
/// cells, whose centroids can be closer together than the match tolerance.
class HexTerritoryManager {
  final ApiService _api;
  final String? _userId;

  final Map<int, TerritoryCell> _cells = {};

  /// Synthetic keys for hexes rendered before their real cellId is known (see
  /// [addCapturedHexes]). Always negative so they can never collide with a
  /// real H3 index.
  int _nextSyntheticId = -1;

  HexTerritoryManager({required ApiService api, required String? userId})
      : _api = api,
        _userId = userId;

  // ── Derived read views ──────────────────────────────────────────────────
  // Computed on demand from the single store instead of maintained as
  // separate fields, so they can never drift out of sync with each other.

  List<TerritoryCell> get allCells => _cells.values.toList();

  Set<int> get userOwnCellIds => _ownCells.map((c) => c.cellId).toSet();

  List<List<List<double>>> get userOwnHexBoundaries =>
      _ownCells.map((c) => c.boundary).toList();

  List<double> get userOwnDecayValues =>
      _ownCells.map((c) => c.decayProgress).toList();

  Map<String, List<List<List<double>>>> get otherHexesByColor {
    final result = <String, List<List<List<double>>>>{};
    for (final cell in _cells.values) {
      if (cell.ownerId == _userId) continue;
      result.putIfAbsent(cell.ownerColor, () => []).add(cell.boundary);
    }
    return result;
  }

  Iterable<TerritoryCell> get _ownCells =>
      _cells.values.where((c) => c.ownerId == _userId);

  /// Loads ALL hexes owned by this user — no viewport limit.
  ///
  /// On a successful fetch the set is cached to disk; when the backend is
  /// unreachable (offline) we fall back to that cache so the user's own hexes
  /// still render on the Start Journey map instead of vanishing (issue #33).
  Future<void> loadUserOwnHexes() async {
    if (_userId == null) return;
    try {
      final cells = await _api.getUserTerritories(_userId);
      _replaceOwnCells(cells);
      await TerritoryCache.save(_userId, cells);
    } catch (e) {
      // A reachable server that still failed (5xx, or a malformed payload that
      // breaks the `as List`/`fromJson` decode) is a real bug, not an offline
      // state — surface it loudly instead of masking it behind stale cache.
      // Kept as a catch-all (not `on Exception`) so a decode `TypeError`, which
      // is an Error rather than an Exception, is logged here too rather than
      // escaping as an unhandled async error to callers that don't await/catch.
      if (!isServerUnreachable(e)) {
        _log.warning('loadUserOwnHexes failed (server reachable)', e);
        return;
      }
      // Offline. Restore the last cached own-hexes, but only if we don't already
      // have fresher data loaded this session (a viewport load may have already
      // populated owned cells).
      if (userOwnCellIds.isEmpty) {
        final cached = await TerritoryCache.load(_userId);
        if (cached != null && cached.isNotEmpty) _replaceOwnCells(cached);
      }
    }
  }

  /// Replaces every currently-tracked user-owned cell with [cells] (keyed
  /// upsert), leaving all other-owned cells untouched.
  void _replaceOwnCells(List<TerritoryCell> cells) {
    _cells.removeWhere((_, c) => c.ownerId == _userId);
    for (final cell in cells) {
      _cells[cell.cellId] = cell;
    }
  }

  /// Loads hexes in a wide area around [lat], [lng].
  Future<void> loadWideArea(double lat, double lng) async {
    try {
      const offset = AppConstants.wideViewportOffset;
      final cells = await _api.getTerritories(
        minLat: lat - offset,
        minLng: lng - offset,
        maxLat: lat + offset,
        maxLng: lng + offset,
      );
      updateFromCells(cells);
    } catch (_) {}
  }

  /// Loads hexes within a viewport bounding box.
  Future<void> loadViewport({
    required double minLat,
    required double minLng,
    required double maxLat,
    required double maxLng,
  }) async {
    try {
      final cells = await _api.getTerritories(
        minLat: minLat,
        minLng: minLng,
        maxLat: maxLat,
        maxLng: maxLng,
      );
      updateFromCells(cells);
    } catch (_) {}
  }

  /// Upserts [cells] into the store by `cellId` (newest data wins), then
  /// evicts excess non-owned cells if the store is over the cache limit.
  void updateFromCells(List<TerritoryCell> cells) {
    for (final cell in cells) {
      _cells[cell.cellId] = cell;
    }
    _evictIfOverCapacity();
  }

  /// Evicts non-owned cells (owned cells are always pinned) once the store
  /// exceeds [AppConstants.maxCachedCells], keeping the same relative order
  /// eviction always used.
  void _evictIfOverCapacity() {
    if (_cells.length <= AppConstants.maxCachedCells) return;
    final ownIds = <int>[];
    final otherIds = <int>[];
    for (final cell in _cells.values) {
      (cell.ownerId == _userId ? ownIds : otherIds).add(cell.cellId);
    }
    final keepCount =
        (AppConstants.maxCachedCells - ownIds.length).clamp(0, otherIds.length);
    final keepOtherIds = otherIds.take(keepCount).toSet();
    _cells.removeWhere(
        (id, cell) => cell.ownerId != _userId && !keepOtherIds.contains(id));
  }

  /// Renders [boundaries] as freshly-captured user-owned hexes immediately,
  /// ahead of the authoritative reload that follows a loop-claim submission.
  ///
  /// The loop-claim response carries boundaries but no cellId (no server
  /// contract change is in scope here), so each gets a synthetic negative key
  /// — never colliding with a real H3 index — instead of being appended to a
  /// side list that could desync from decay/id state. [loadUserOwnHexes]'s
  /// full-replace semantics (`_replaceOwnCells`) drop these placeholders as
  /// soon as the real, id-bearing set arrives.
  void addCapturedHexes(List<List<List<double>>> boundaries) {
    for (final boundary in boundaries) {
      final id = _nextSyntheticId--;
      _cells[id] = TerritoryCell(
        cellId: id,
        ownerId: _userId ?? '',
        ownerColor: '',
        boundary: boundary,
      );
    }
  }

  /// Integrates a single step-claimed hex into persistent state as a keyed
  /// upsert — idempotent by construction (assigning `_cells[cellId]` again is
  /// a no-op change) instead of the previous "check a derived set, then push
  /// onto parallel lists" approach. [wasStolen] no longer needs special
  /// handling: a keyed upsert overwrites whoever held `cellId` before,
  /// stolen or not, so the parameter is kept only for call-site compatibility.
  void integrateStepClaim(List<List<double>> boundary, int cellId, bool wasStolen) {
    final existing = _cells[cellId];
    _cells[cellId] = TerritoryCell(
      cellId: cellId,
      ownerId: _userId ?? '',
      ownerColor: existing?.ownerColor ?? '',
      ownerName: existing?.ownerName ?? '',
      boundary: boundary,
      parentCellId: existing?.parentCellId ?? 0,
    );
  }

  /// Applies real-time hex ownership changes from SignalR.
  /// Returns true if any visible change occurred (caller should rebuild map).
  ///
  /// The event carries the cellId (`h3Index`) but no boundary, so the
  /// boundary is recovered from the existing keyed entry. A hex never seen by
  /// this client was never visible, so there is nothing to repaint — unlike
  /// the previous centroid-distance match, a cellId lookup can't confuse two
  /// adjacent cells.
  bool applyRealtimeChanges(List<HexChangeEvent> events) {
    if (events.isEmpty) return false;

    bool changed = false;
    for (final event in events) {
      final cellId = int.tryParse(event.h3Index);
      if (cellId == null) continue;

      final existing = _cells[cellId];
      if (existing == null) continue;

      _cells[cellId] = TerritoryCell(
        cellId: cellId,
        ownerId: event.newOwnerId,
        ownerColor: event.newOwnerColor,
        ownerName: event.newOwnerDisplayName,
        boundary: existing.boundary,
        parentCellId: existing.parentCellId,
        // The event carries no cooldown/decay; the real values arrive with
        // the next viewport load (both default to "no cooldown, fresh").
      );
      changed = true;
    }

    return changed;
  }

  /// Returns all unique H3 res-3 parent cell IDs from currently loaded cells.
  /// These are the SignalR group keys the client should subscribe to.
  Set<String> getActiveRegionIds() {
    final ids = <String>{};
    for (final cell in _cells.values) {
      if (cell.parentCellId != 0) {
        ids.add(cell.parentCellId.toString());
      }
    }
    return ids;
  }
}
