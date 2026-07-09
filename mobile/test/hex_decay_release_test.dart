import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/features/journey/hex_territory_manager.dart';
import 'package:myloop/shared/models/territory_cell.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/territory_realtime_service.dart';

/// Regression tests for issue #104 (ML-ERR-007): the decay reaper deleted cells
/// server-side with no SignalR event, so every client kept rendering the released
/// hexes ("ghost territory") until its next viewport poll — and the Home/idle app
/// never polls. The server now broadcasts HexesReleased; the manager must drop the
/// released hexes from every render layer.
void main() {
  const me = 'user-me';
  const rival = 'user-rival';
  const rivalColor = '#FF0000';

  // Boundaries with distinct centers so the color-layer matching is unambiguous.
  List<List<double>> boundaryAt(double lat, double lng) => [
        [lat, lng],
        [lat + 0.001, lng],
        [lat + 0.001, lng + 0.001],
        [lat, lng + 0.001],
      ];

  TerritoryCell cell(int id, String owner, String color, double lat, double lng) =>
      TerritoryCell(
        cellId: id,
        ownerId: owner,
        ownerColor: color,
        ownerName: owner,
        boundary: boundaryAt(lat, lng),
        parentCellId: 7,
      );

  HexTerritoryManager newManager() =>
      HexTerritoryManager(api: ApiService(), userId: me);

  group('HexTerritoryManager.removeCells', () {
    test('drops a released rival hex from otherHexesByColor and allCells', () {
      final manager = newManager();
      manager.updateFromCells([
        cell(701, rival, rivalColor, 12.900, 77.500),
        cell(702, rival, rivalColor, 12.910, 77.510),
      ]);
      expect(manager.otherHexesByColor[rivalColor], hasLength(2));

      final changed = manager.removeCells(['701']);

      expect(changed, isTrue);
      expect(manager.otherHexesByColor[rivalColor], hasLength(1));
      expect(manager.allCells.map((c) => c.cellId), [702]);
    });

    test('drops a released own hex from the owned layers', () {
      final manager = newManager();
      manager.updateFromCells([
        cell(703, me, '#0000FF', 12.920, 77.520),
        cell(704, me, '#0000FF', 12.930, 77.530),
      ]);
      expect(manager.userOwnCellIds, {703, 704});
      expect(manager.userOwnHexBoundaries, hasLength(2));

      final changed = manager.removeCells(['703']);

      expect(changed, isTrue);
      expect(manager.userOwnCellIds, {704});
      expect(manager.userOwnHexBoundaries, hasLength(1));
      expect(manager.userOwnDecayValues, hasLength(1));
      expect(manager.allCells.map((c) => c.cellId), [704]);
    });

    test('is a no-op for hexes this client never loaded', () {
      final manager = newManager();
      manager.updateFromCells([cell(705, rival, rivalColor, 12.940, 77.540)]);

      final changed = manager.removeCells(['999', 'not-a-number']);

      expect(changed, isFalse);
      expect(manager.otherHexesByColor[rivalColor], hasLength(1));
      expect(manager.allCells, hasLength(1));
    });

    test('removes an empty color group entirely', () {
      final manager = newManager();
      manager.updateFromCells([cell(706, rival, rivalColor, 12.950, 77.550)]);

      manager.removeCells(['706']);

      expect(manager.otherHexesByColor.containsKey(rivalColor), isFalse);
    });
  });

  group('HexesReleasedEvent.fromJson', () {
    test('parses the server payload (string ids — H3 ids exceed 2^53)', () {
      final event = HexesReleasedEvent.fromJson({
        'parentCellId': '590112371752960',
        'h3Indexes': ['631196237151909887', '631196237151909888'],
      });

      expect(event.parentCellId, '590112371752960');
      expect(event.h3Indexes, hasLength(2));
      expect(event.h3Indexes.first, '631196237151909887');
    });

    test('tolerates a missing or empty payload', () {
      final event = HexesReleasedEvent.fromJson({});
      expect(event.parentCellId, '');
      expect(event.h3Indexes, isEmpty);
    });
  });
}
