import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/game_state_cache.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/shared/state/exploration_slice.dart';
import 'package:myloop/shared/state/hydration.dart';
import 'package:myloop/shared/state/missions_slice.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Pins [getApplicationDocumentsPath] to a real temp dir so the cache lands on
/// an inspectable file during tests (same pattern as step_claim_queue_test).
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// Stand-in [ApiService] whose game-state response is controllable. `null`
/// models an offline device (the real service swallows the Dio error and
/// returns null, api_service.dart:317-325).
class _FakeApi extends ApiService {
  _FakeApi(this.gameState) : super(baseUrl: 'http://localhost');

  final Map<String, dynamic>? gameState;

  @override
  Future<Map<String, dynamic>?> getGameState(String userId) async => gameState;
}

/// Exposes a real [Ref] so the production [hydrateAllSlicesFromRef] runs against
/// the test container's provider graph.
final _hydrateHarness = Provider<Future<void> Function()>(
  (ref) => () => hydrateAllSlicesFromRef(ref),
);

Map<String, dynamic> _mission(String id) => {
      'id': id,
      'type': 0,
      'description': 'Walk 1km',
      'targetValue': 10,
      'currentProgress': 3,
      'xpReward': 50,
      'isCompleted': false,
    };

Map<String, dynamic> _neighborhood(int id) => {
      'neighborhoodId': id,
      'centerLat': 12.34,
      'centerLng': 56.78,
      'exploredCount': 5,
      'ownedCount': 2,
      'totalCount': 20,
      'percent': 0.25,
      'areaName': 'Downtown',
    };

ProviderContainer _containerWith(ApiService api, String userId) {
  final container = ProviderContainer(
    overrides: [apiServiceProvider.overrideWithValue(api)],
  );
  // Give the profile a server user id so hydration runs.
  container.read(userProfileProvider.notifier).setFromApi(
        userId: userId,
        avatarId: 0,
        color: '#000000',
        displayName: 'Player',
      );
  return container;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('game_state_cache_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('GameStateCache codec', () {
    test('encode/decode round-trips userId, missions and exploration', () {
      final cached = CachedGameState(
        userId: 'u1',
        missions: [_mission('m1'), _mission('m2')],
        exploration: [_neighborhood(1)],
      );

      final decoded = GameStateCache.decode(GameStateCache.encode(cached))!;

      expect(decoded.userId, 'u1');
      expect(decoded.missions.length, 2);
      expect((decoded.missions.first as Map)['id'], 'm1');
      expect((decoded.exploration.single as Map)['neighborhoodId'], 1);
    });

    test('decode returns null on malformed JSON (no throw)', () {
      expect(GameStateCache.decode('not json {'), isNull);
    });

    test('decode returns null when the user id is missing', () {
      expect(GameStateCache.decode('{"missions":[],"exploration":[]}'), isNull);
    });

    test('decode tolerates absent missions/exploration as empty lists', () {
      final decoded = GameStateCache.decode('{"userId":"u1"}')!;
      expect(decoded.missions, isEmpty);
      expect(decoded.exploration, isEmpty);
    });
  });

  group('GameStateCache disk durability', () {
    test('save then load yields the exact persisted set from disk', () async {
      await GameStateCache.save(
        'u1',
        [_mission('m1'), _mission('m2')],
        [_neighborhood(7)],
      );

      // Fresh read straight off disk must match what was written (memory==disk).
      final loaded = await GameStateCache.load('u1');

      expect(loaded, isNotNull);
      expect(
        loaded!.missions.map((m) => (m as Map)['id']).toSet(),
        {'m1', 'm2'},
      );
      expect((loaded.exploration.single as Map)['neighborhoodId'], 7);
    });

    test('load rejects a cache written for a different user', () async {
      await GameStateCache.save('userA', [_mission('m1')], [_neighborhood(1)]);

      expect(await GameStateCache.load('userB'), isNull);
      expect(await GameStateCache.load('userA'), isNotNull);
    });

    test('save with empty userId persists nothing', () async {
      await GameStateCache.save('', [_mission('m1')], const []);
      expect(await GameStateCache.load('u1'), isNull);
    });

    test('clear empties the on-disk cache', () async {
      await GameStateCache.save('u1', [_mission('m1')], const []);
      await GameStateCache.clear();
      expect(await GameStateCache.load('u1'), isNull);
    });
  });

  group('offline hydration restore (issue #34 regression)', () {
    test('offline restores last-known missions and exploration from cache',
        () async {
      // The user saw real data online once → it is cached on disk.
      await GameStateCache.save(
        'u1',
        [_mission('m1'), _mission('m2')],
        [_neighborhood(1)],
      );

      // Now the device is offline: getGameState returns null.
      final container = _containerWith(_FakeApi(null), 'u1');
      addTearDown(container.dispose);

      await container.read(_hydrateHarness)();

      // Without the offline-restore wiring these slices stay empty (the bug);
      // the fix repopulates them from the cache.
      expect(
        container.read(missionsSliceProvider).missions.map((m) => m.id).toSet(),
        {'m1', 'm2'},
      );
      expect(
        container.read(explorationSliceProvider).neighborhoods.single.neighborhoodId,
        1,
      );
    });

    test('offline with no cache leaves slices empty without crashing',
        () async {
      final container = _containerWith(_FakeApi(null), 'u1');
      addTearDown(container.dispose);

      await container.read(_hydrateHarness)();

      expect(container.read(missionsSliceProvider).missions, isEmpty);
      expect(container.read(explorationSliceProvider).neighborhoods, isEmpty);
    });

    test('offline does not restore another user\'s cached cards', () async {
      await GameStateCache.save('userA', [_mission('m1')], [_neighborhood(1)]);

      // A different account is signed in on the same device, now offline.
      final container = _containerWith(_FakeApi(null), 'userB');
      addTearDown(container.dispose);

      await container.read(_hydrateHarness)();

      expect(container.read(missionsSliceProvider).missions, isEmpty);
      expect(container.read(explorationSliceProvider).neighborhoods, isEmpty);
    });

    test('a successful online hydration writes the cache for offline reuse',
        () async {
      final container = _containerWith(
        _FakeApi({
          'missions': [_mission('m1')],
          'exploration': [_neighborhood(9)],
        }),
        'u1',
      );
      addTearDown(container.dispose);

      await container.read(_hydrateHarness)();

      final cached = await GameStateCache.load('u1');
      expect(cached, isNotNull);
      expect((cached!.missions.single as Map)['id'], 'm1');
      expect((cached.exploration.single as Map)['neighborhoodId'], 9);
    });
  });
}
