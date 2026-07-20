/// Regression tests for issue #102 (ML-ERR-005): the app-wide SignalR hub
/// connection was scoped to the Journey screen's lifecycle instead of the
/// login session, so leaving Journey once (`disconnect()` in dispose) left
/// the app deaf to live stats/XP/mission/achievement pushes for the rest of
/// the session; and a failed `start()` left `connect()` permanently wedged
/// into a silent no-op on every later call.
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:myloop/features/profile/profile_screen.dart';
import 'package:myloop/shared/services/auth_service.dart';
import 'package:myloop/shared/services/territory_realtime_service.dart';

/// Implements (not extends) [AuthService] so the fake never runs the real
/// class's eager `FirebaseAuth.instance` field initializer, which throws
/// without a Firebase app initialized in a widget test.
class _FakeAuthService implements AuthService {
  int signOutCalls = 0;

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }

  @override
  User? get currentUser => null;

  @override
  Stream<User?> get authStateChanges => const Stream.empty();

  @override
  Future<User?> signInWithGoogle() async => null;

  @override
  Future<User?> signInWithApple() async => null;
}

/// Fake realtime service that tracks disconnect() calls without touching a
/// real SignalR connection.
class _FakeRealtime extends TerritoryRealtimeService {
  _FakeRealtime() : super(baseUrl: 'http://test.local');

  int disconnectCalls = 0;

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }
}

void main() {
  test(
    'a failed connect does not wedge the service — a later connect() actually retries',
    () async {
      // Nothing listens on this loopback port, so start() fails fast.
      final service = TerritoryRealtimeService(baseUrl: 'http://127.0.0.1:1');

      await service.connect(userId: 'user-1');
      expect(service.isConnected, isFalse);
      expect(service.connectAttempts, 1);

      // Pre-fix: `_hubConnection` stayed non-null after the failed start(), so
      // this second call bailed on the `if (_hubConnection != null) return`
      // guard without ever attempting to reconnect.
      await service.connect(userId: 'user-1');
      expect(
        service.connectAttempts,
        2,
        reason: 'a previous failed start() must not wedge future connect() calls into a no-op',
      );
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  testWidgets(
    'signing out disconnects the app-lifecycle-scoped realtime hub (#102)',
    (tester) async {
      final realtime = _FakeRealtime();
      final authService = _FakeAuthService();

      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, __) => const ProfileScreen()),
        GoRoute(path: '/login', builder: (_, __) => const SizedBox()),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            territoryRealtimeProvider.overrideWithValue(realtime),
            authServiceProvider.overrideWithValue(authService),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(realtime.disconnectCalls, 0);

      await tester.tap(find.text('Sign Out'));
      await tester.pumpAndSettle();

      expect(authService.signOutCalls, 1);
      expect(
        realtime.disconnectCalls,
        1,
        reason: 'logout must tear down the hub connection that Journey no longer does',
      );
    },
  );
}
