/// Re-synchronizes global game state after a SignalR reconnect or an app
/// foreground resume.
///
/// docs/architecture/realtime.md ("Reconnect & resync — the critical
/// correctness rule") mandates a full snapshot re-fetch on every reconnect,
/// because the hub never replays deltas missed while disconnected. Without
/// this, a player can keep seeing stats/missions/XP from before an outage —
/// or, worst case, believe they still own territory that was actually stolen
/// while they were offline.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:myloop/shared/services/territory_realtime_service.dart';
import 'package:myloop/shared/state/hydration.dart';

final _log = Logger('RealtimeResync');

/// Side-effect-only provider: as long as something holds it alive (see
/// [MyLoopApp], which reads it once at the app root) it re-hydrates all game
/// state slices on every hub reconnect and on every app-foreground resume.
/// Riverpod only ever runs the build function once per app session, so this
/// is safe to read from multiple places.
final realtimeResyncProvider = Provider<void>((ref) {
  final realtime = ref.watch(territoryRealtimeProvider);

  final reconnectSub = realtime.onReconnected.listen((_) {
    _log.info('Hub reconnected — re-hydrating game state');
    hydrateAllSlicesFromRef(ref);
  });

  final lifecycleListener = AppLifecycleListener(
    onResume: () {
      if (!realtime.isConnected) return;
      _log.info('App resumed — re-hydrating game state');
      hydrateAllSlicesFromRef(ref);
    },
  );

  ref.onDispose(() {
    reconnectSub.cancel();
    lifecycleListener.dispose();
  });
});
