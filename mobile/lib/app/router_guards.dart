/// Route-guard logic for the app router, kept in its own file so tests can exercise it
/// WITHOUT importing `router.dart` — which pulls in every screen (home_tab, journey, …)
/// and would drag thousands of uncovered UI lines into the coverage denominator (#130).
library;

import 'package:flutter/material.dart';
import 'package:myloop/features/profile/user_profile_screen.dart';

/// Routes reachable without a signed-in session. Everything else is protected.
///
/// Onboarding routes (`/avatar`, `/set-home`) are intentionally NOT here: they are
/// only reached once Firebase already has a session, so an *unauthenticated* caller
/// deep-linking to them should still be bounced to `/login`.
const authRoutes = {'/login', '/local-signup'};

/// Pure route guard (see the router's `redirect`). Returns the path to redirect to,
/// or `null` to allow the navigation.
///
/// Fail-closed: an unauthenticated caller may only sit on an auth route; any other
/// target sends them to `/login`. Authenticated callers are never redirected away
/// from `/login` here — the login screen performs the session bootstrap (profile
/// load, slice hydration, SignalR connect, push init) and then navigates onward
/// itself, so short-circuiting it would launch the app with unhydrated state.
///
/// Offline is handled implicitly: Firebase restores the session from disk with no
/// network, so [isAuthenticated] is true offline and a cached user is not bounced.
String? authRedirect({required bool isAuthenticated, required String location}) {
  if (!isAuthenticated && !authRoutes.contains(location)) return '/login';
  return null;
}

/// Builds a [UserProfileScreen] from route `extra`, or `null` when `extra` is
/// missing or any required field is absent/mistyped.
UserProfileScreen? userProfileFromExtra(Object? extra) {
  if (extra is! Map<String, dynamic>) return null;
  final userId = extra['userId'];
  final name = extra['name'];
  final avatarId = extra['avatar'];
  final color = extra['color'];
  final rank = extra['rank'];
  if (userId is! String || name is! String || avatarId is! int || color is! String || rank is! int) {
    return null;
  }
  return UserProfileScreen(
    userId: userId,
    name: name,
    avatarId: avatarId,
    color: color,
    rank: rank,
  );
}

/// Shown when `/user-profile` is entered without the data it needs, instead of
/// throwing. Lets the user navigate back rather than hitting a red error screen.
class UnavailableProfileScreen extends StatelessWidget {
  const UnavailableProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: const Center(child: Text("This profile isn't available.")),
    );
  }
}
