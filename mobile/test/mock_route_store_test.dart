/// Tests for the debug saved-route store (#160).
///
/// Follows the repo's disk-concurrency test pattern (see CLAUDE.md pre-check-in
/// gate): stub `path_provider` via the platform interface, assert the
/// durability invariant — a fresh load that reads ONLY from disk equals the
/// live in-memory library AND the exact expected surviving set — and force
/// interleaved unawaited writes to prove serialization. Without the store's
/// chained `_pendingWrite` the interleaved-write test is the one that guards
/// the file against torn/out-of-order writes.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:myloop/shared/services/mock/mock_route_store.dart';
import 'package:myloop/shared/services/mock/mock_walk_config.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

MockWalkConfig _configAt(double lat) =>
    MockWalkConfig(startPoint: LatLng(lat, -122.0));

void main() {
  late Directory tmp;
  late ProviderContainer container;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mock_route_store_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  MockRouteLibraryNotifier notifier() =>
      container.read(mockRouteLibraryProvider.notifier);

  Future<MockRouteLibrary> memory() =>
      container.read(mockRouteLibraryProvider.future);

  group('codec', () {
    test('encode/decode round trips routes and lastUsed', () {
      final library = MockRouteLibrary(
        routes: [
          SavedMockRoute(name: 'A', savedAt: DateTime(2026, 7, 1), config: _configAt(37.1)),
        ],
        lastUsed: _configAt(37.9),
      );
      final decoded = MockRouteStore.decode(MockRouteStore.encode(library));
      expect(decoded.routes.map((r) => r.name), ['A']);
      expect(decoded.lastUsed!.startPoint.latitude, 37.9);
    });

    test('malformed file content → empty library, no throw', () {
      expect(MockRouteStore.decode('{{{not json').routes, isEmpty);
      expect(MockRouteStore.decode('[1,2,3]').routes, isEmpty);
    });

    test('an individually corrupt route entry is skipped, not fatal', () {
      final raw = MockRouteStore.encode(MockRouteLibrary(routes: [
        SavedMockRoute(name: 'good', savedAt: DateTime(2026, 7, 1), config: _configAt(37.1)),
      ]));
      final tampered = raw.replaceFirst('"routes":[', '"routes":["garbage",');
      expect(MockRouteStore.decode(tampered).routes.map((r) => r.name), ['good']);
    });
  });

  group('durability (disk == memory + exact surviving set)', () {
    test('save/delete sequence survives a fresh disk-only load', () async {
      await memory(); // hydrate
      await notifier().saveRoute('alpha', _configAt(37.1));
      await notifier().saveRoute('beta', _configAt(37.2));
      await notifier().saveRoute('gamma', _configAt(37.3));
      await notifier().deleteRoute('beta');
      await notifier().setLastUsed(_configAt(37.5));

      final inMemory = await memory();
      final fromDisk = await MockRouteStore.load();

      expect(fromDisk.routes.map((r) => r.name), inMemory.routes.map((r) => r.name));
      // Exact surviving set, newest first — disk==memory alone could pass empty.
      expect(fromDisk.routes.map((r) => r.name), ['gamma', 'alpha']);
      expect(fromDisk.lastUsed!.startPoint.latitude, 37.5);
    });

    test('saving an existing name overwrites instead of duplicating', () async {
      await memory();
      await notifier().saveRoute('same', _configAt(37.1));
      await notifier().saveRoute('same', _configAt(37.7));

      final fromDisk = await MockRouteStore.load();
      expect(fromDisk.routes, hasLength(1));
      expect(fromDisk.routes.single.config.startPoint.latitude, 37.7);
    });

    test('caps at maxSavedRoutes, dropping the oldest', () async {
      await memory();
      for (var i = 0; i <= MockRouteStore.maxSavedRoutes; i++) {
        await notifier().saveRoute('route-$i', _configAt(37.0));
      }
      final fromDisk = await MockRouteStore.load();
      expect(fromDisk.routes, hasLength(MockRouteStore.maxSavedRoutes));
      expect(fromDisk.routes.first.name, 'route-${MockRouteStore.maxSavedRoutes}');
      expect(fromDisk.routes.map((r) => r.name), isNot(contains('route-0')));
    });

    test('a corrupt file on disk loads as empty and is recoverable', () async {
      final file = File('${tmp.path}/mock_routes.json');
      await file.writeAsString('total garbage {{');
      expect((await MockRouteStore.load()).routes, isEmpty);

      await memory();
      await notifier().saveRoute('fresh', _configAt(37.1));
      expect((await MockRouteStore.load()).routes.map((r) => r.name), ['fresh']);
    });
  });

  group('write serialization', () {
    test('interleaved unawaited mutations still converge: disk == final memory', () async {
      await memory();
      // ~25 iterations of conflicting, unawaited ops (see skill pattern) — with
      // unserialized writes the final file can be a stale or torn snapshot.
      for (var i = 0; i < 25; i++) {
        await Future.wait([
          notifier().saveRoute('churn-$i', _configAt(37.0 + i / 1000)),
          notifier().saveRoute('keeper', _configAt(37.5)),
          notifier().deleteRoute('churn-${i - 1}'),
        ]);
      }

      final inMemory = await memory();
      final fromDisk = await MockRouteStore.load();
      expect(fromDisk.routes.map((r) => r.name).toList(),
          inMemory.routes.map((r) => r.name).toList());
      expect(fromDisk.routes.map((r) => r.name), contains('keeper'));
      expect(fromDisk.routes.map((r) => r.name), contains('churn-24'));
    });
  });
}
