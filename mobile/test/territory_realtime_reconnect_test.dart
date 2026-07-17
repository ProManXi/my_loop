/// Regression test for issue #102 (ML-ERR-005) — a failed connection attempt used to
/// permanently wedge [TerritoryRealtimeService.connect]: `_hubConnection` was left
/// non-null after a failed `HubConnection.start()`, so the "already connected" guard
/// at the top of `connect()` silently short-circuited every later retry. In practice
/// this meant one bad connection attempt (e.g. no network at login) left the app deaf
/// to realtime updates for the rest of the session — no error, just silent no-ops.
///
/// This drives a REAL `TerritoryRealtimeService` (no mocking) against an address that
/// refuses the connection immediately (a reserved, unassigned loopback port), so
/// `start()` fails fast and deterministically without needing a live server or
/// network access.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/territory_realtime_service.dart';

void main() {
  test('a failed connect() does not wedge the service — the next call retries',
      () async {
    final service = TerritoryRealtimeService(baseUrl: 'http://127.0.0.1:1');

    await service.connect(token: 'tok', userId: 'user-1');
    expect(service.isConnected, isFalse);
    expect(service.connectAttempts, 1);

    // Pre-fix: the failed start() above left `_hubConnection` non-null, so this
    // second call short-circuited at the top of connect() without even trying —
    // connectAttempts would stay at 1 forever, and the app would never reconnect.
    await service.connect(token: 'tok', userId: 'user-1');
    expect(service.isConnected, isFalse);
    expect(service.connectAttempts, 2);
  });
}
