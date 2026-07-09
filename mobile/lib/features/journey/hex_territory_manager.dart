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

class HexTerritoryManager {
  final ApiService _api;
  final String? _userId;

  List<List<List<double>>> userOwnHexBoundaries = [];
  List<double> userOwnDecayValues = [];
  Map<String, List<List<List<double>>>> otherHexesByColor = {};
  List<TerritoryCell> allCells = [];
  Set<int> userOwnCellIds = {};

  HexTerritoryManager({required ApiService api, required String? userId})
      : _api = api,
        _userId = userId;

  /// Loads ALL hexes owned by this user — no viewport limit.
  ///
  /// On a successful fetch the set is cached to disk; when the backend is
  /// unreachable (offline) we fall back to that cache so the user's own hexes
  /// still render on the Start Journey map instead of vanishing (issue #33).
  Future<void> loadUserOwnHexes() async {
    if (_userId == null) return;
    try {
      final cells = await _api.getUserTerritories(_userId);
      _applyUserOwnCells(cells);
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
        if (cached != null && cached.isNotEmpty) _applyUserOwnCells(cached);
      }
    }
  }

  /// Replaces the user-owned hex state with [cells] and merges them into the
  /// shared [allCells] cache (newest data wins).
  void _applyUserOwnCells(List<TerritoryCell> cells) {
    userOwnHexBoundaries = cells.map((c) => c.boundary).toList();
    userOwnDecayValues = cells.map((c) => c.decayProgress).toList();
    userOwnCellIds = cells.map((c) => c.cellId).toSet();
    allCells = [
      ...allCells.where((c) => c.ownerId != _userId),
      ...cells,
    ];
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

  /// Splits cells into user-owned and others (grouped by owner color).
  void updateFromCells(List<dynamic> cells) {
    // Merge new cells into allCells by cellId (dedup)
    final cellMap = <int, TerritoryCell>{};
    for (final c in allCells) {
      cellMap[c.cellId] = c;
    }
    for (final c in cells) {
      final cell = c as TerritoryCell;
      cellMap[cell.cellId] = cell; // newer data wins
    }

    // Update user-owned tracking from ALL cells (viewport may reveal owned cells)
    final newUserBoundaries = <List<List<double>>>[];
    final newUserDecay = <double>[];
    final newUserCellIds = <int>{};
    final otherByColor = <String, List<List<List<double>>>>{};

    for (final cell in cellMap.values) {
      if (cell.ownerId == _userId) {
        newUserCellIds.add(cell.cellId);
        newUserBoundaries.add(cell.boundary);
        newUserDecay.add(cell.decayProgress);
      } else {
        otherByColor.putIfAbsent(cell.ownerColor, () => []).add(cell.boundary);
      }
    }

    userOwnHexBoundaries = newUserBoundaries;
    userOwnDecayValues = newUserDecay;
    userOwnCellIds = newUserCellIds;
    otherHexesByColor = otherByColor;

    // Evict oldest non-owned cells if cache exceeds limit
    final allList = cellMap.values.toList();
    if (allList.length > AppConstants.maxCachedCells) {
      final ownCells = allList.where((c) => c.ownerId == _userId).toList();
      final otherCells = allList.where((c) => c.ownerId != _userId).toList();
      final keepCount = AppConstants.maxCachedCells - ownCells.length;
      allCells = [...ownCells, ...otherCells.take(keepCount.clamp(0, otherCells.length))];
    } else {
      allCells = allList;
    }
  }

  /// Adds captured hex boundaries to the user's owned list.
  void addCapturedHexes(List<List<List<double>>> boundaries) {
    userOwnHexBoundaries = [...userOwnHexBoundaries, ...boundaries];
  }

  /// Integrates a single step-claimed hex into persistent state.
  /// Removes it from other-players display (if it was stolen) and adds to user-owned.
  void integrateStepClaim(List<List<double>> boundary, int cellId, bool wasStolen) {
    // Remove from other-player display if stolen
    if (wasStolen) {
      final center = _computeCenter(boundary);
      _removeFromOthersByCenter(center[0], center[1]);
    }
    // Add to user's owned hexes (avoid duplicates)
    if (!userOwnCellIds.contains(cellId)) {
      userOwnCellIds.add(cellId);
      userOwnHexBoundaries.add(boundary);
      userOwnDecayValues.add(0.0); // Fresh hex, no decay
    }
  }

  List<double> _computeCenter(List<List<double>> boundary) {
    double latSum = 0, lngSum = 0;
    for (final p in boundary) {
      latSum += p[0];
      lngSum += p[1];
    }
    return [latSum / boundary.length, lngSum / boundary.length];
  }

  /// Applies real-time hex ownership changes from SignalR.
  /// Returns true if any visible change occurred (caller should rebuild map).
  ///
  /// The event carries no boundary, so it is recovered from client state: the
  /// allCells cache first, else the render layer the hex is removed from. A hex
  /// never seen by this client was never visible, so there is nothing to repaint.
  bool applyRealtimeChanges(List<HexChangeEvent> events) {
    if (events.isEmpty) return false;

    bool changed = false;
    for (final event in events) {
      List<List<double>>? boundary;

      // Update allCells in place so the boundary and parentCellId (the SignalR
      // region subscription key) survive the ownership change.
      final cellIdx = allCells.indexWhere((c) => c.cellId.toString() == event.h3Index);
      if (cellIdx >= 0) {
        final old = allCells[cellIdx];
        boundary = old.boundary;
        allCells[cellIdx] = TerritoryCell(
          cellId: old.cellId,
          ownerId: event.newOwnerId,
          ownerColor: event.newOwnerColor,
          ownerName: event.newOwnerDisplayName,
          boundary: old.boundary,
          parentCellId: old.parentCellId,
          // The event carries no cooldown; the real value arrives with the
          // next viewport load.
        );
      }

      // If this hex was stolen FROM us, remove from our owned list. Boundaries
      // and decay values are parallel arrays — remove both at the same index.
      if (event.previousOwnerId == _userId) {
        userOwnCellIds.removeWhere((id) => id.toString() == event.h3Index);
        for (var i = userOwnHexBoundaries.length - 1; i >= 0; i--) {
          if (_boundaryMatchesCenter(userOwnHexBoundaries[i], event.centerLat, event.centerLng)) {
            boundary ??= userOwnHexBoundaries[i];
            userOwnHexBoundaries.removeAt(i);
            if (i < userOwnDecayValues.length) userOwnDecayValues.removeAt(i);
          }
        }
        changed = true;
      }

      // Remove from the previous owner's color group, keeping the boundary so
      // the hex can be re-added instead of vanishing until the next reload.
      final removedFromOthers =
          _removeFromOthersByCenter(event.centerLat, event.centerLng);
      boundary ??= removedFromOthers;

      if (event.newOwnerId == _userId) {
        // Captured BY us (from another device or real-time confirmation) —
        // upsert into our owned layer.
        final cellId = int.tryParse(event.h3Index);
        if (cellId != null && boundary != null && !userOwnCellIds.contains(cellId)) {
          userOwnCellIds.add(cellId);
          userOwnHexBoundaries.add(boundary);
          userOwnDecayValues.add(0.0); // fresh capture, no decay
        }
        changed = true;
      } else {
        // Another player captured/stole this hex — repaint it under the new
        // owner's color group instead of only removing it.
        if (boundary != null) {
          otherHexesByColor.putIfAbsent(event.newOwnerColor, () => []).add(boundary);
        }
        changed = true;
      }
    }

    return changed;
  }

  /// Removes decay-released cells from every render layer (server-authoritative map:
  /// the reaper's HexesReleased broadcast must clear them immediately, not at the next
  /// viewport poll). Returns true if anything visible changed (caller repaints).
  ///
  /// A hex this client never loaded has no boundary to match in the color layers —
  /// it was never visible, so there is nothing to repaint (same limitation as
  /// [applyRealtimeChanges]).
  bool removeCells(Iterable<String> h3Indexes) {
    var changed = false;
    for (final idStr in h3Indexes) {
      final cellId = int.tryParse(idStr);
      if (cellId == null) continue;

      List<List<double>>? boundary;
      final idx = allCells.indexWhere((c) => c.cellId == cellId);
      if (idx >= 0) {
        boundary = allCells[idx].boundary;
        allCells.removeAt(idx);
        changed = true;
      }

      if (userOwnCellIds.remove(cellId)) {
        changed = true;
        if (boundary != null) {
          final center = _computeCenter(boundary);
          // Parallel arrays — remove boundary and decay value at the same index.
          for (var i = userOwnHexBoundaries.length - 1; i >= 0; i--) {
            if (_boundaryMatchesCenter(userOwnHexBoundaries[i], center[0], center[1])) {
              userOwnHexBoundaries.removeAt(i);
              if (i < userOwnDecayValues.length) userOwnDecayValues.removeAt(i);
            }
          }
        }
      }

      if (boundary != null) {
        final center = _computeCenter(boundary);
        changed |= _removeFromOthersByCenter(center[0], center[1]) != null;
      }
    }
    return changed;
  }

  /// Remove a hex from otherHexesByColor by matching its center coordinates.
  /// Returns the first removed boundary (null if nothing matched) so callers
  /// can re-add it under a new owner.
  List<List<double>>? _removeFromOthersByCenter(double lat, double lng) {
    List<List<double>>? removed;
    for (final entry in otherHexesByColor.entries) {
      entry.value.removeWhere((b) {
        if (!_boundaryMatchesCenter(b, lat, lng)) return false;
        removed ??= b;
        return true;
      });
    }
    // Remove empty color groups
    otherHexesByColor.removeWhere((_, boundaries) => boundaries.isEmpty);
    return removed;
  }

  bool _boundaryMatchesCenter(List<List<double>> boundary, double lat, double lng) {
    if (boundary.isEmpty) return false;
    double avgLat = 0, avgLng = 0;
    for (final p in boundary) {
      avgLat += p[0];
      avgLng += p[1];
    }
    avgLat /= boundary.length;
    avgLng /= boundary.length;
    return (avgLat - lat).abs() < 0.0001 && (avgLng - lng).abs() < 0.0001;
  }

  /// Returns all unique H3 res-3 parent cell IDs from currently loaded cells.
  /// These are the SignalR group keys the client should subscribe to.
  Set<String> getActiveRegionIds() {
    final ids = <String>{};
    for (final cell in allCells) {
      if (cell.parentCellId != 0) {
        ids.add(cell.parentCellId.toString());
      }
    }
    return ids;
  }
}
