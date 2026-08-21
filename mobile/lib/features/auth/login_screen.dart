/// Login screen — the app's entry point for unauthenticated users.
///
/// Presents a Duolingo-inspired welcome page with a mascot emoji, app
/// branding, and OAuth sign-in buttons (Google & Apple). On successful
/// authentication, navigates to the avatar picker screen.
library;

import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:myloop/app/theme.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/auth_service.dart';
import 'package:myloop/shared/services/profile_cache.dart';
import 'package:myloop/shared/services/push_notification_service.dart';
import 'package:myloop/shared/services/territory_realtime_service.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/shared/state/hydration.dart';
import 'package:myloop/shared/widgets/big_button.dart';
import 'package:url_launcher/url_launcher.dart';

/// The initial login/welcome screen shown to unauthenticated users.
///
/// Follows a simple vertical layout: mascot, branding, spacer, CTA buttons,
/// and legal text. On startup, if a Firebase session is already restored
/// (e.g., after an app restart), the user is automatically routed to /home
/// without seeing the login UI.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _autoSigningIn = false;

  @override
  void initState() {
    super.initState();
    // After first frame: check whether Firebase already has a restored session.
    // This fires every time the login screen mounts (e.g., after app restart).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final authService = ref.read(authServiceProvider);
      final currentUser = authService.currentUser;
      if (currentUser != null) {
        setState(() => _autoSigningIn = true);
        _routeAfterAuth(currentUser.uid);
      }
    });
  }

  /// Builds the full-screen login layout with branding and sign-in CTAs.
  @override
  Widget build(BuildContext context) {
    // While auto-routing an already-authenticated session, show a spinner
    // so the login buttons never flash on screen.
    if (_autoSigningIn) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const Spacer(flex: 2),

              // Big mascot/logo
              const Text('🌍', style: TextStyle(fontSize: 80)),
              const SizedBox(height: 16),

              // App name
              Text(
                'MyLoop',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 8),

              // Tagline
              Text(
                'Walk. Capture. Conquer.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppColors.grey,
                ),
              ),

              const Spacer(flex: 3),

              // Google sign in button
              BigButton(
                label: 'CONTINUE WITH GOOGLE',
                icon: Icons.login,
                onPressed: () => _signInWithGoogle(),
              ),
              const SizedBox(height: 12),

              // Apple sign in button
              BigButton(
                label: 'CONTINUE WITH APPLE',
                icon: Icons.apple,
                color: AppColors.dark,
                onPressed: () => _signInWithApple(),
              ),
              const SizedBox(height: 16),

              // Local account creation
              OutlinedButton(
                onPressed: () => context.push('/local-signup'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  side: const BorderSide(color: AppColors.greyLight, width: 2),
                ),
                child: const Text(
                  'CREATE ACCOUNT WITHOUT LOGIN',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.dark),
                ),
              ),
              const SizedBox(height: 12),

              // Dev skip button — only visible in debug mode
              if (const bool.fromEnvironment('dart.vm.product') == false)
                TextButton(
                  onPressed: () => _devSkip(),
                  child: Text(
                    'SKIP (DEV MODE)',
                    style: TextStyle(color: AppColors.grey, fontSize: 12),
                  ),
                ),

              const Spacer(flex: 1),

              // Terms text with tappable links
              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.grey,
                    fontSize: 12,
                  ),
                  children: [
                    const TextSpan(text: 'By continuing, you agree to our '),
                    TextSpan(
                      text: 'Terms',
                      style: const TextStyle(decoration: TextDecoration.underline, fontWeight: FontWeight.w600),
                      recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse('https://destitute-living-bullpen.ngrok-free.dev/terms')),
                    ),
                    const TextSpan(text: ' & '),
                    TextSpan(
                      text: 'Privacy Policy',
                      style: const TextStyle(decoration: TextDecoration.underline, fontWeight: FontWeight.w600),
                      recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse('https://destitute-living-bullpen.ngrok-free.dev/privacy')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  bool _isSigningIn = false;

  /// Returns true if the exception represents a deliberate user cancellation
  /// (not a real error). These should be silently swallowed.
  bool _isCancellation(Object e) {
    if (e is PlatformException) {
      final code = e.code.toLowerCase();
      return code == 'sign_in_canceled' ||
             code == 'sign_in_cancelled' ||
             code == 'canceled' ||
             code == 'user_cancelled' ||
             code == 'com.apple.authenticationservices.authorizationerror' ||
             e.message?.toLowerCase().contains('cancel') == true;
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('cancel') || msg.contains('aborted') || msg.contains('dismissed');
  }

  Future<void> _signInWithGoogle() async {
    if (_isSigningIn) return;
    setState(() => _isSigningIn = true);
    try {
      final authService = ref.read(authServiceProvider);
      final user = await authService.signInWithGoogle();
      if (user != null && mounted) {
        await _routeAfterAuth(user.uid);
      }
    } catch (e) {
      if (mounted && !_isCancellation(e)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sign in failed: $e'), backgroundColor: AppColors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSigningIn = false);
    }
  }

  Future<void> _signInWithApple() async {
    if (_isSigningIn) return;
    setState(() => _isSigningIn = true);
    try {
      final authService = ref.read(authServiceProvider);
      final user = await authService.signInWithApple();
      if (user != null && mounted) {
        await _routeAfterAuth(user.uid);
      }
    } catch (e) {
      if (mounted && !_isCancellation(e)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sign in failed: $e'), backgroundColor: AppColors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSigningIn = false);
    }
  }

  /// After auth (fresh or restored session): load profile and go to /home,
  /// or go to /avatar if this is a new user.
  Future<void> _routeAfterAuth(String firebaseUid) async {
    try {
      final api = ref.read(apiServiceProvider);
      final existing = await api.getUserByUid(firebaseUid);
      if (existing != null && mounted) {
        // Fetch rank while we have the API connection
        int rank = 0;
        try {
          final lb = await api.getLeaderboard(lat: 0, lng: 0, userId: existing.id, scope: 'city');
          rank = lb.myRank ?? 0;
        } catch (_) {}

        ref.read(userProfileProvider.notifier).setFromApi(
          userId: existing.id,
          avatarId: existing.avatarId,
          color: existing.color,
          displayName: existing.displayName,
          hexCount: existing.hexCount,
          streak: existing.streak,
          distanceKm: existing.distanceKm,
          rank: rank,
        );
        // Cache the profile bound to this Firebase user so a later offline
        // launch can restore this session instead of bouncing them back to
        // login (issue #19). Binding to firebaseUid keeps a different account
        // on the same device from inheriting it offline.
        await ProfileCache.save(firebaseUid, ref.read(userProfileProvider));

        // Initialize push notifications after login
        ref.read(pushNotificationProvider).initialize(existing.id);

        // Connect SignalR with auth token for personal event group. A
        // provider (not a point-in-time string) so an automatic reconnect
        // after the ~1h token expiry fetches a fresh one instead of failing
        // auth silently (#102).
        await ref.read(territoryRealtimeProvider).connect(
          tokenProvider: () async => await fb.FirebaseAuth.instance.currentUser?.getIdToken(),
          userId: existing.id,
        );

        // Hydrate all state slices from unified endpoint
        await hydrateAllSlices(ref);

        if (mounted) context.go('/home');
        return;
      }
      // User not found (null return) — proceed to avatar picker
      if (mounted) {
        setState(() => _autoSigningIn = false);
        context.go('/avatar');
      }
    } catch (e) {
      // Server unreachable. If this is an already-authenticated session and we
      // have a cached profile, let the user back into the app offline (issue
      // #19) instead of stranding them on the login screen.
      if (await _restoreOfflineSession(e, firebaseUid)) return;

      // No cached session to fall back on (e.g. brand-new login with no
      // network) — show the retry prompt and don't blindly route to avatar.
      if (mounted) {
        setState(() => _autoSigningIn = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot reach server. Check your connection and try again.'),
            backgroundColor: Colors.red.shade700,
            action: SnackBarAction(
              label: 'RETRY',
              textColor: Colors.white,
              onPressed: () => _routeAfterAuth(firebaseUid),
            ),
          ),
        );
      }
    }
  }

  /// When the backend is unreachable on launch but Firebase still has a
  /// restored session, bring the user in using their last cached profile so
  /// they stay logged in offline (issue #19). [firebaseUid] is the user who
  /// just authenticated; the cached profile is only restored when it is bound
  /// to that same UID, so a different account on this device can never inherit
  /// the previous user's profile/session offline. Returns `true` only if it
  /// actually routed the user to /home; `false` otherwise (so the caller can
  /// fall back to the retry prompt).
  Future<bool> _restoreOfflineSession(Object error, String firebaseUid) async {
    if (!isServerUnreachable(error)) return false;
    if (ref.read(authServiceProvider).currentUser == null) return false;

    final cached = await ProfileCache.load();
    if (cached == null || cached.firebaseUid != firebaseUid) return false;

    final profile = cached.profile;
    final userId = profile.userId;
    if (userId == null) return false;

    ref.read(userProfileProvider.notifier).setFromApi(
          userId: userId,
          avatarId: profile.avatarId,
          color: profile.color,
          displayName: profile.displayName,
          hexCount: profile.hexCount,
          streak: profile.streak,
          distanceKm: profile.distanceKm,
          rank: profile.rank,
        );

    // Report success only if we actually navigated; if the widget was disposed
    // mid-await we did not route, and the caller must not treat it as handled.
    if (!mounted) return false;
    context.go('/home');
    return true;
  }

  Future<void> _devSkip() async {
    try {
      final api = ref.read(apiServiceProvider);
      final user = await api.getUserByUid('uid_robin');
      if (user != null) {
        int rank = 0;
        try {
          final lb = await api.getLeaderboard(lat: 0, lng: 0, userId: user.id, scope: 'city');
          rank = lb.myRank ?? 0;
        } catch (_) {}

        ref.read(userProfileProvider.notifier).setFromApi(
          userId: user.id,
          avatarId: user.avatarId,
          color: user.color,
          displayName: user.displayName,
          hexCount: user.hexCount,
          streak: user.streak,
          distanceKm: user.distanceKm,
          rank: rank,
        );

        // Connect SignalR + hydrate slices
        await ref.read(territoryRealtimeProvider).connect(
          tokenProvider: () async => await fb.FirebaseAuth.instance.currentUser?.getIdToken(),
          userId: user.id,
        );
        await hydrateAllSlices(ref);
      }
      if (mounted) context.go('/home');
    } catch (e) {
      if (mounted) context.go('/home');
    }
  }
}
