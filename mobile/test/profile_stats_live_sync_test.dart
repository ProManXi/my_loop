/// Regression test for issue #30 — "Hex count is different while tracking vs in-app" —
/// retargeted for issue #113 ("Two parallel profile stores").
///
/// Root cause (#30): the server pushes an authoritative [UserStatsDelta] over SignalR on
/// every claim (including each batch-step claim while walking), but only
/// `profileSliceProvider` consumed it, so surfaces reading `userProfileProvider` stayed
/// frozen at their pre-walk value mid-walk.
///
/// The #30 fix made `userProfileProvider` *also* listen to the same stream — which
/// promptly caused #113: two independently-updated copies of the same numbers that could
/// drift under scope/tie edge cases. The real fix is a single owner: `profileSliceProvider`
/// now owns every stat field (hexCount/streak/distanceKm/rank) exclusively, and
/// `UserProfile` (`userProfileProvider`) carries identity only (userId/avatar/color/name) —
/// it has no stat fields at all, so this file would fail to *compile* (not just fail at
/// runtime) if a stat field crept back onto it.
///
/// This test drives a fake realtime service and asserts: (1) `profileSliceProvider` tracks
/// every pushed delta, and (2) `userProfileProvider` identity is completely inert to those
/// pushes — proving there is exactly one owner of game stats.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/territory_realtime_service.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/shared/state/profile_slice.dart';

/// Counts rebuilds of whatever it watches — the fields under test (identity vs
/// stats), not screen-specific widgets — to prove the two providers are
/// independent: a stat delta must rebuild only what watches
/// `profileSliceProvider`, never what watches `userProfileProvider`.
class _BuildCounter extends ConsumerWidget {
  const _BuildCounter({required this.counter, required this.watch});
  final ValueNotifier<int> counter;
  final Object Function(WidgetRef ref) watch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    watch(ref);
    counter.value++;
    return const SizedBox.shrink();
  }
}

/// Fake realtime service whose [onUserStats] stream is driven by the test.
/// Only the stat-push stream is overridden; no SignalR connection is made.
class _FakeRealtime extends TerritoryRealtimeService {
  _FakeRealtime() : super(baseUrl: 'http://test.local');

  final StreamController<UserStatsDelta> _stats =
      StreamController<UserStatsDelta>.broadcast();

  void push(UserStatsDelta delta) => _stats.add(delta);

  @override
  Stream<UserStatsDelta> get onUserStats => _stats.stream;

  Future<void> close() => _stats.close();
}

UserStatsDelta _delta({
  required int hexCount,
  int streak = 0,
  double distanceKm = 0,
}) =>
    UserStatsDelta.fromJson({
      'hexCount': hexCount,
      'totalHexesCaptured': hexCount,
      'totalHexesStolen': 0,
      'streak': streak,
      'isStreakActive': streak > 0,
      'distanceKm': distanceKm,
    });

void main() {
  late _FakeRealtime realtime;
  late ProviderContainer container;

  setUp(() {
    realtime = _FakeRealtime();
    container = ProviderContainer(overrides: [
      territoryRealtimeProvider.overrideWithValue(realtime),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await realtime.close();
  });

  // Lets the broadcast stream deliver its queued event to the listener.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a live stat push updates the displayed hex count mid-walk', () async {
    // Establish the pre-walk baseline the Map/Home badge shows.
    container.read(profileSliceProvider.notifier).applyStats(
          hexCount: 100,
          streak: 4,
          distanceKm: 5.0,
          rank: 7,
        );
    expect(container.read(profileSliceProvider).hexCount, 100);

    // Server pushes the authoritative count after capturing 30 hexes this walk.
    realtime.push(_delta(hexCount: 130, streak: 5, distanceKm: 6.2));
    await settle();

    final profile = container.read(profileSliceProvider);
    expect(profile.hexCount, 130, reason: 'Map badge must track the live server count');
    expect(profile.streak, 5);
    expect(profile.distanceKm, 6.2);
  });

  test('stat pushes never touch identity — it lives on a separate, unrelated provider', () async {
    container.read(userProfileProvider.notifier).setFromApi(
          userId: 'user-1',
          avatarId: 2,
          color: '#6C5CE7',
          displayName: 'Robin',
        );
    container.read(profileSliceProvider.notifier).applyStats(
          hexCount: 100,
          streak: 4,
          distanceKm: 5.0,
          rank: 7,
        );

    realtime.push(_delta(hexCount: 142, streak: 5, distanceKm: 6.2));
    await settle();

    // Stats moved…
    final stats = container.read(profileSliceProvider);
    expect(stats.hexCount, 142);
    expect(stats.streak, 5);
    expect(stats.distanceKm, 6.2);
    // …identity is on a provider that never subscribed to this stream, so it
    // is byte-for-byte unchanged — not merely "preserved" by a copyWith.
    final identity = container.read(userProfileProvider);
    expect(identity.userId, 'user-1');
    expect(identity.avatarId, 2);
    expect(identity.color, '#6C5CE7');
    expect(identity.displayName, 'Robin');
  });

  test('successive pushes during a walk keep replacing the displayed count', () async {
    container.read(profileSliceProvider.notifier).applyStats(
          hexCount: 50,
          streak: 1,
          distanceKm: 0,
        );

    realtime.push(_delta(hexCount: 55));
    await settle();
    expect(container.read(profileSliceProvider).hexCount, 55);

    realtime.push(_delta(hexCount: 61));
    await settle();
    expect(container.read(profileSliceProvider).hexCount, 61);
  });

  testWidgets('a stats delta rebuilds only what watches profileSliceProvider, not identity',
      (tester) async {
    final identityBuilds = ValueNotifier(0);
    final statsBuilds = ValueNotifier(0);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Column(
            children: [
              _BuildCounter(counter: identityBuilds, watch: (ref) => ref.watch(userProfileProvider)),
              _BuildCounter(
                counter: statsBuilds,
                watch: (ref) => ref.watch(profileSliceProvider.select((s) => s.hexCount)),
              ),
            ],
          ),
        ),
      ),
    );

    final identityBuildsBeforePush = identityBuilds.value;
    final statsBuildsBeforePush = statsBuilds.value;

    realtime.push(_delta(hexCount: 999));
    await tester.pump();

    expect(statsBuilds.value, greaterThan(statsBuildsBeforePush),
        reason: 'the stats watcher must rebuild when profileSliceProvider changes');
    expect(identityBuilds.value, identityBuildsBeforePush,
        reason: 'the identity watcher must not rebuild — it never subscribed to stat pushes');
  });
}
