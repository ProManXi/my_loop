import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/features/journey/hex_territory_manager.dart';
import 'package:myloop/shared/models/territory_cell.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/territory_realtime_service.dart';

/// Regression tests for issue #86: a live HexOwnershipChanged event for a hex
/// owned by another player removed it from the render layers without re-adding
/// it under the new owner's colour, so the hex vanished until the next
/// viewport reload.
void main() {
  const me = 'user-me';
  const p1 = 'user-p1';
  const p2 = 'user-p2';
  const p1Color = '#FF0000';
  const p2Color = '#00FF00';

  // A hex boundary whose center is (12.9005, 77.5005).
  final boundary = [
    [12.900, 77.500],
    [12.901, 77.500],
    [12.901, 77.501],
    [12.900, 77.501],
  ];

  final farBoundary = [
    [40.700, 74.000],
    [40.701, 74.000],
    [40.701, 74.001],
    [40.700, 74.001],
  ];

  TerritoryCell cell(int id, String owner, String color,
          {List<List<double>>? hexBoundary}) =>
      TerritoryCell(
        cellId: id,
        ownerId: owner,
        ownerColor: color,
        ownerName: owner,
        boundary: hexBoundary ?? boundary,
        parentCellId: 7,
      );

  HexChangeEvent event({
    required String newOwnerId,
    required String newOwnerColor,
    String? previousOwnerId,
  }) =>
      HexChangeEvent(
        h3Index: '601',
        centerLat: 12.9005,
        centerLng: 77.5005,
        newOwnerId: newOwnerId,
        newOwnerColor: newOwnerColor,
        newOwnerDisplayName: newOwnerId,
        previousOwnerId: previousOwnerId,
      );

  HexTerritoryManager newManager() =>
      HexTerritoryManager(api: ApiService(), userId: me);

  group('applyRealtimeChanges', () {
    test('hex stolen between two other players repaints under new owner', () {
      final manager = newManager();
      manager.updateFromCells([cell(601, p1, p1Color)]);
      expect(manager.otherHexesByColor[p1Color], hasLength(1));

      final changed = manager.applyRealtimeChanges(
          [event(newOwnerId: p2, newOwnerColor: p2Color, previousOwnerId: p1)]);

      expect(changed, isTrue);
      // Not just removed — present under the NEW owner's colour.
      expect(manager.otherHexesByColor[p1Color], isNull);
      expect(manager.otherHexesByColor[p2Color], hasLength(1));
      // allCells is updated in place, not evicted.
      final cached = manager.allCells.singleWhere((c) => c.cellId == 601);
      expect(cached.ownerId, p2);
      expect(cached.ownerColor, p2Color);
      expect(cached.parentCellId, 7, reason: 'region subscription key survives');
    });

    test('hex stolen from us moves to the thief\'s layer and decay stays in sync', () {
      final manager = newManager();
      manager.updateFromCells([cell(601, me, '#123456')]);
      expect(manager.userOwnCellIds, contains(601));
      expect(manager.userOwnDecayValues, hasLength(1));

      final changed = manager.applyRealtimeChanges(
          [event(newOwnerId: p2, newOwnerColor: p2Color, previousOwnerId: me)]);

      expect(changed, isTrue);
      expect(manager.userOwnCellIds, isNot(contains(601)));
      expect(manager.userOwnHexBoundaries, isEmpty);
      expect(manager.userOwnDecayValues, isEmpty,
          reason: 'decay values are indexed parallel to boundaries');
      expect(manager.otherHexesByColor[p2Color], hasLength(1));
    });

    test('hex gained by us (other device) moves into the user-owned layer', () {
      final manager = newManager();
      manager.updateFromCells([cell(601, p1, p1Color)]);

      final changed = manager.applyRealtimeChanges(
          [event(newOwnerId: me, newOwnerColor: '#123456', previousOwnerId: p1)]);

      expect(changed, isTrue);
      expect(manager.otherHexesByColor, isEmpty);
      expect(manager.userOwnCellIds, contains(601));
      expect(manager.userOwnHexBoundaries, hasLength(1));
      expect(manager.userOwnDecayValues, hasLength(1));
      final cached = manager.allCells.singleWhere((c) => c.cellId == 601);
      expect(cached.ownerId, me);
    });

    test('gain event for a hex we already own does not duplicate it', () {
      final manager = newManager();
      manager.updateFromCells([cell(601, me, '#123456')]);

      manager.applyRealtimeChanges(
          [event(newOwnerId: me, newOwnerColor: '#123456')]);

      expect(manager.userOwnCellIds, hasLength(1));
      expect(manager.userOwnHexBoundaries, hasLength(1));
      expect(manager.userOwnDecayValues, hasLength(1));
    });

    test('event for a hex not in any client state is a no-op that does not crash', () {
      final manager = newManager();
      manager.updateFromCells([cell(999, p1, p1Color, hexBoundary: farBoundary)]);

      manager.applyRealtimeChanges(
          [event(newOwnerId: p2, newOwnerColor: p2Color, previousOwnerId: p1)]);

      // The unrelated hex is untouched; nothing appeared for the unknown hex.
      expect(manager.otherHexesByColor[p1Color], hasLength(1));
      expect(manager.otherHexesByColor[p2Color], isNull);
    });
  });
}
