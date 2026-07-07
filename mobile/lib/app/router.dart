/// MyLoop - Application Routing Configuration
library;

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:myloop/app/router_guards.dart';
import 'package:myloop/features/dev/mock_walk_screen.dart';
import 'package:myloop/features/auth/login_screen.dart';
import 'package:myloop/features/auth/avatar_picker_screen.dart';
import 'package:myloop/features/auth/local_signup_screen.dart';
import 'package:myloop/features/auth/set_home_screen.dart';
import 'package:myloop/features/home/home_screen.dart';
import 'package:myloop/features/home/home_tab.dart';
import 'package:myloop/features/journey/journey_screen.dart';
import 'package:myloop/features/leaderboard/leaderboard_screen.dart';
import 'package:myloop/features/achievements/achievements_screen.dart';
import 'package:myloop/features/profile/profile_screen.dart';
import 'package:myloop/features/history/walk_history_screen.dart';
import 'package:myloop/features/notifications/notifications_screen.dart';

/// No-animation page transition for tab switches.
CustomTransitionPage _noTransitionPage(Widget child, GoRouterState state, String tabKey) {
  return CustomTransitionPage(
    key: ValueKey(tabKey),
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) => child,
  );
}

/// A [Listenable] that fires whenever Firebase auth state changes, so the router
/// re-evaluates [authRedirect] on sign-in/sign-out (e.g. bouncing to `/login` the
/// moment the user signs out).
class _AuthRefreshListenable extends ChangeNotifier {
  _AuthRefreshListenable(Stream<User?> stream) {
    _sub = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<User?> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// The global router instance.
final router = GoRouter(
  initialLocation: '/login',
  refreshListenable: _AuthRefreshListenable(FirebaseAuth.instance.authStateChanges()),
  redirect: (context, state) => authRedirect(
    isAuthenticated: FirebaseAuth.instance.currentUser != null,
    location: state.matchedLocation,
  ),
  routes: [
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    GoRoute(path: '/local-signup', builder: (context, state) => const LocalSignupScreen()),
    GoRoute(path: '/avatar', builder: (context, state) => AvatarPickerScreen(prefillName: (state.extra as Map<String, dynamic>?)?['name'] as String?)),
    GoRoute(path: '/set-home', builder: (context, state) => const SetHomeScreen()),

    ShellRoute(
      builder: (context, state, child) => HomeScreen(child: child),
      routes: [
        GoRoute(
          path: '/home',
          pageBuilder: (context, state) => _noTransitionPage(const HomeTab(), state, 'home'),
        ),
        GoRoute(
          path: '/leaderboard',
          pageBuilder: (context, state) => _noTransitionPage(const LeaderboardScreen(), state, 'leaderboard'),
        ),
        GoRoute(
          path: '/achievements',
          pageBuilder: (context, state) => _noTransitionPage(const AchievementsScreen(), state, 'achievements'),
        ),
      ],
    ),

    GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen()),

    GoRoute(path: '/journey', builder: (context, state) => const JourneyScreen()),
    // Debug-only mock walk simulator (#29) — excluded from release builds.
    if (kDebugMode)
      GoRoute(path: '/dev/mock-walk', builder: (context, state) => const MockWalkScreen()),
    GoRoute(path: '/walk-history', builder: (context, state) => const WalkHistoryScreen()),
    GoRoute(path: '/notifications', builder: (context, state) => const NotificationsScreen()),
    GoRoute(
      path: '/user-profile',
      builder: (context, state) {
        // extra is caller-supplied and absent on a cold deep-link or a malformed
        // push tap. The old unconditional `state.extra as Map` threw and crashed
        // the route; validate every field and fall back to a recoverable screen.
        final screen = userProfileFromExtra(state.extra);
        return screen ?? const UnavailableProfileScreen();
      },
    ),
  ],
);