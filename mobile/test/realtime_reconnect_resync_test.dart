/// Regression tests for issue #111 — "No snapshot re-fetch on SignalR
/// reconnect — the documented critical resync rule is unimplemented".
///
/// Root cause: `TerritoryRealtimeService`'s `onreconnected` hub callback only
/// re-joined groups (`_resubscribeAll`); nothing told the rest of the app a
/// reconnect happened, so no surface ever re-fetched a snapshot. Missed
/// deltas during the outage were lost forever — a player could keep seeing
/// stats/missions from before the outage, or (worst case, on the map) keep
/// showing territory they'd actually lost.
///
/// The fix adds `TerritoryRealtimeService.onReconnected` (fired once regions
/// are re-joined) and a `realtimeResyncProvider` that re-hydrates every game
/// state slice whenever it fires, plus on every app-foreground resume.
/// These tests FAIL without the fix (no `onReconnected` stream existed, and
/// nothing consumed it).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/realtime_resync.dart';
import 'package:myloop/shared/services/territory_realtime_service.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/shared/state/missions_slice.dart';

/// Stand-in [ApiService] whose game-state response is controllable, mirroring
/// the fake used in game_state_offline_cache_test.dart.
class _FakeApi extends ApiService {
  _FakeApi(this.gameState) : super(baseUrl: 'http://localhost');

  final Map<String, dynamic> gameState;

  @override
  Future<Map<String, dynamic>?> getGameState(String userId) async => gameState;
}

/// Real [TerritoryRealtimeService] with a controllable connection state,
/// used to drive `handleReconnected` without a live hub.
class _ControllableRealtime extends TerritoryRealtimeService {
  _ControllableRealtime() : super(baseUrl: 'http://test.local');

  bool connectedOverride = false;

  @override
  bool get isConnected => connectedOverride;
}

Map<String, dynamic> _mission(String id) => {
      'id': id,
      'type': 0,
      'description': 'Walk 1km',
      'targetValue': 10,
      'currentProgress': 3,
      'xpReward': 50,
      'isCompleted': false,
    };

ProviderContainer _containerWith(ApiService api, TerritoryRealtimeService realtime, String userId) {
  final container = ProviderContainer(overrides: [
    apiServiceProvider.overrideWithValue(api),
    territoryRealtimeProvider.overrideWithValue(realtime),
  ]);
  container.read(userProfileProvider.notifier).setFromApi(
        userId: userId,
        avatarId: 0,
        color: '#000000',
        displayName: 'Player',
        hexCount: 0,
        streak: 0,
        distanceKm: 0,
      );
  return container;
}

/// Drives a real foreground transition on the shared binding.
///
/// Both `SchedulerBinding.handleAppLifecycleStateChanged` and
/// `AppLifecycleListener.didChangeAppLifecycleState` ignore a dispatch that
/// repeats the current state, and the listener additionally asserts that
/// `resumed` is only ever entered from `null`/`inactive`/`detached`. Going
/// via `inactive` is therefore the only sequence that actually fires
/// `onResume` — dispatching `resumed` alone is silently a no-op.
void _resumeApp() {
  final binding = TestWidgetsFlutterBinding.instance;
  binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  // realtimeResyncProvider builds an AppLifecycleListener as soon as it's
  // read, even from a plain `test()` block that never pumps a widget — make
  // sure a binding exists up front so that construction doesn't throw.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerritoryRealtimeService.onReconnected', () {
    test('handleReconnected notifies onReconnected listeners exactly once', () async {
      final service = TerritoryRealtimeService(baseUrl: 'http://test.local');
      addTearDown(service.dispose);

      var fireCount = 0;
      final sub = service.onReconnected.listen((_) => fireCount++);
      addTearDown(sub.cancel);

      // No live hub connection needed — the extracted handler is what the
      // real `onreconnected` hub callback now delegates to.
      await service.handleReconnected(connectionId: 'conn-1');
      await pumpEventQueue();

      expect(fireCount, 1);
    });

    test('handleReconnected is safe even if never connected (no hub yet)', () async {
      final service = TerritoryRealtimeService(baseUrl: 'http://test.local');
      addTearDown(service.dispose);

      var fired = false;
      final sub = service.onReconnected.listen((_) => fired = true);
      addTearDown(sub.cancel);

      await service.handleReconnected();
      await pumpEventQueue();

      expect(fired, isTrue);
    });
  });

  group('realtimeResyncProvider — reconnect resync', () {
    test('a hub reconnect re-hydrates game state slices from a fresh fetch', () async {
      final realtime = _ControllableRealtime();
      addTearDown(realtime.dispose);
      final api = _FakeApi({
        'missions': [_mission('m1')],
        'exploration': [],
      });
      final container = _containerWith(api, realtime, 'u1');
      addTearDown(container.dispose);

      // Establish the wiring (mirrors reading it once at the app root).
      container.read(realtimeResyncProvider);
      expect(container.read(missionsSliceProvider).missions, isEmpty,
          reason: 'nothing hydrated yet — only connecting/reconnecting triggers a fetch');

      await realtime.handleReconnected(connectionId: 'conn-1');
      // Let the async hydration triggered by the reconnect event complete.
      await pumpEventQueue();

      expect(
        container.read(missionsSliceProvider).missions.map((m) => m.id).toSet(),
        {'m1'},
        reason: 'reconnect must re-fetch the snapshot — missed deltas are never replayed',
      );
    });
  });

  group('realtimeResyncProvider — app-foreground resync', () {
    // The lifecycle state lives on the process-wide binding, so a previous
    // test leaving it at `resumed` would make the next resume a no-op.
    setUp(() => TestWidgetsFlutterBinding.instance.resetInternalState());

    test('resuming the app while connected re-hydrates game state', () async {
      final realtime = _ControllableRealtime()..connectedOverride = true;
      addTearDown(realtime.dispose);
      final api = _FakeApi({
        'missions': [_mission('m2')],
        'exploration': [],
      });
      final container = _containerWith(api, realtime, 'u1');
      addTearDown(container.dispose);

      container.read(realtimeResyncProvider);
      expect(container.read(missionsSliceProvider).missions, isEmpty);

      _resumeApp();
      await pumpEventQueue();

      expect(
        container.read(missionsSliceProvider).missions.map((m) => m.id).toSet(),
        {'m2'},
      );
    });

    test('resuming the app while disconnected does not fetch', () async {
      final realtime = _ControllableRealtime()..connectedOverride = false;
      addTearDown(realtime.dispose);
      final api = _FakeApi({
        'missions': [_mission('m3')],
        'exploration': [],
      });
      final container = _containerWith(api, realtime, 'u1');
      addTearDown(container.dispose);

      container.read(realtimeResyncProvider);

      _resumeApp();
      await pumpEventQueue();

      expect(TestWidgetsFlutterBinding.instance.lifecycleState, AppLifecycleState.resumed,
          reason: 'the resume must really have been delivered, or this asserts nothing');
      expect(container.read(missionsSliceProvider).missions, isEmpty,
          reason: 'no live connection means no snapshot to resync against');
    });
  });
}
