import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:myloop/app/router.dart';
import 'package:myloop/features/profile/user_profile_screen.dart';

/// Router guards for #130 (ML-ERR-033):
///  - authRedirect fail-closes unauthenticated deep-links into protected routes.
///  - userProfileFromExtra never throws on missing/malformed `extra`.
///  - the /user-profile route renders UnavailableProfileScreen instead of crashing.
void main() {
  group('authRedirect', () {
    test('unauthenticated on a protected route is bounced to /login', () {
      expect(authRedirect(isAuthenticated: false, location: '/home'), '/login');
      expect(authRedirect(isAuthenticated: false, location: '/journey'), '/login');
      expect(authRedirect(isAuthenticated: false, location: '/user-profile'), '/login');
      // Onboarding routes require a session, so an unauth caller is bounced too.
      expect(authRedirect(isAuthenticated: false, location: '/avatar'), '/login');
      expect(authRedirect(isAuthenticated: false, location: '/set-home'), '/login');
    });

    test('unauthenticated on an auth route is allowed (no login bounce loop)', () {
      expect(authRedirect(isAuthenticated: false, location: '/login'), isNull);
      expect(authRedirect(isAuthenticated: false, location: '/local-signup'), isNull);
    });

    test('authenticated is never redirected away — /login stays the bootstrap screen', () {
      // Crucially NOT forced to /home: the login screen runs session bootstrap first.
      expect(authRedirect(isAuthenticated: true, location: '/login'), isNull);
      expect(authRedirect(isAuthenticated: true, location: '/home'), isNull);
      expect(authRedirect(isAuthenticated: true, location: '/avatar'), isNull);
    });
  });

  group('userProfileFromExtra', () {
    final validExtra = <String, dynamic>{
      'userId': 'u1',
      'name': 'Robin',
      'avatar': 3,
      'color': '#FF0000',
      'rank': 7,
    };

    test('builds the screen from well-formed extra', () {
      final screen = userProfileFromExtra(validExtra);
      expect(screen, isA<UserProfileScreen>());
      expect(screen!.userId, 'u1');
      expect(screen.rank, 7);
    });

    test('returns null instead of throwing when extra is null', () {
      expect(userProfileFromExtra(null), isNull);
    });

    test('returns null when extra is not a map', () {
      expect(userProfileFromExtra('nope'), isNull);
      expect(userProfileFromExtra(42), isNull);
    });

    test('returns null when a required key is missing', () {
      final missing = Map<String, dynamic>.from(validExtra)..remove('rank');
      expect(userProfileFromExtra(missing), isNull);
    });

    test('returns null when a field is the wrong type', () {
      final wrong = Map<String, dynamic>.from(validExtra)..['avatar'] = 'three';
      expect(userProfileFromExtra(wrong), isNull);
    });
  });

  group('/user-profile route rendering', () {
    // Reuses the app's real route logic (userProfileFromExtra + UnavailableProfileScreen)
    // in a pumpable MaterialApp.router — the global `router` can't be pumped in a unit test
    // because its redirect/refresh touch FirebaseAuth.instance.
    GoRouter buildTestRouter() => GoRouter(
          initialLocation: '/user-profile',
          routes: [
            GoRoute(
              path: '/user-profile',
              builder: (context, state) =>
                  userProfileFromExtra(state.extra) ?? const UnavailableProfileScreen(),
            ),
          ],
        );

    testWidgets('renders the fallback when navigated without extra (no crash)', (tester) async {
      await tester.pumpWidget(MaterialApp.router(routerConfig: buildTestRouter()));
      await tester.pumpAndSettle();

      expect(find.byType(UnavailableProfileScreen), findsOneWidget);
      expect(find.text("This profile isn't available."), findsOneWidget);
    });

    testWidgets('renders UnavailableProfileScreen directly', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: UnavailableProfileScreen()));
      expect(find.text("This profile isn't available."), findsOneWidget);
    });
  });
}
