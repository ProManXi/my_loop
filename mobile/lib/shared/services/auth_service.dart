/// MyLoop — Authentication Service
///
/// Provides a unified interface for user authentication using Firebase Auth
/// with federated identity providers (Google Sign-In and Apple Sign-In).
///
/// Architecture:
///   - Wraps [FirebaseAuth] so that feature-level code never interacts with
///     Firebase directly — all auth operations flow through this service.
///   - Exposes [authStateChanges] as a stream so Riverpod providers can
///     reactively rebuild UI when the user signs in or out.
///   - Google Sign-In requires a one-time `initialize()` call before first
///     use; this is tracked via [_googleInitialized] to avoid redundant calls.
///
/// Lifecycle:
///   Managed via [authServiceProvider] (a Riverpod `Provider`). Because
///   [AuthService] holds no disposable resources (Firebase manages its own
///   lifecycle), no `onDispose` hook is needed.
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:myloop/shared/services/game_state_cache.dart';
import 'package:myloop/shared/services/notification_cache.dart';
import 'package:myloop/shared/services/profile_cache.dart';
import 'package:myloop/shared/services/territory_cache.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Authentication Service
// ─────────────────────────────────────────────────────────────────────────────

/// Handles all authentication flows for the MyLoop application.
///
/// Supported providers:
///   - **Google** — via `google_sign_in` plugin + Firebase credential exchange.
///   - **Apple** — via Firebase's built-in `signInWithProvider` (Sign in with Apple).
///
/// After successful authentication, the resulting [User] object contains
/// the Firebase UID, display name, email, and photo URL which are used to
/// create or match the user record in the MyLoop backend API.
class AuthService {
  /// Firebase Auth singleton instance — shared across the app.
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Tracks whether [GoogleSignIn.initialize] has been called this session.
  /// The Google Sign-In SDK must be initialized exactly once before any
  /// authentication attempt.
  bool _googleInitialized = false;

  // ─────────────────────────────────────────────────────────────────────────
  // Getters
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns the currently signed-in [User], or `null` if no user session
  /// exists. Useful for synchronous checks (e.g., route guards).
  User? get currentUser => _auth.currentUser;

  /// A real-time stream that emits the current [User] whenever the auth state
  /// changes (sign-in, sign-out, token refresh). Consumed by
  /// [authStateProvider] to drive reactive UI updates.
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ─────────────────────────────────────────────────────────────────────────
  // Google Sign-In
  // ─────────────────────────────────────────────────────────────────────────

  /// Authenticates the user via Google Sign-In and exchanges the result for
  /// a Firebase credential.
  ///
  /// Flow:
  ///   1. Initialize the Google Sign-In SDK (first call only).
  ///   2. Present the Google account chooser / consent screen.
  ///   3. Retrieve the Google ID token from the authenticated session.
  ///   4. Create a Firebase [AuthCredential] from the ID token.
  ///   5. Sign in to Firebase with that credential.
  ///
  /// Returns the authenticated [User] on success, or `null` if the user
  /// cancels the Google sign-in flow.
  ///
  /// Throws [FirebaseAuthException] if credential exchange fails.
  Future<User?> signInWithGoogle() async {
    // Lazy-initialize the Google Sign-In SDK. Calling initialize() more than
    // once is a no-op in most versions, but we guard it explicitly.
    if (!_googleInitialized) {
      await GoogleSignIn.instance.initialize(
        serverClientId: '274879524094-3rda7p3t80mi67nahuvq0v58tf5oh114.apps.googleusercontent.com',
      );
      _googleInitialized = true;
    }

    // Trigger the native Google Sign-In UI (account picker + consent).
    final googleUser = await GoogleSignIn.instance.authenticate();

    // Extract the OAuth tokens needed by Firebase.
    final googleAuth = googleUser.authentication;

    // Build a Firebase credential using only the ID token. The access token
    // is not required for Firebase Auth but could be used for Google API calls.
    final credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
    );

    // Exchange the Google credential for a Firebase user session.
    final result = await _auth.signInWithCredential(credential);
    return result.user;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Apple Sign-In
  // ─────────────────────────────────────────────────────────────────────────

  /// Authenticates the user via Sign in with Apple using Firebase's
  /// built-in provider support.
  ///
  /// Flow:
  ///   1. Configure an [AppleAuthProvider] requesting `email` and `name` scopes.
  ///   2. Firebase handles the native Apple Sign-In sheet and credential
  ///      exchange internally via `signInWithProvider`.
  ///
  /// Returns the authenticated [User] on success.
  ///
  /// Note: Apple only provides the user's name/email on the **first** sign-in.
  /// Subsequent sign-ins return `null` for those fields — the backend must
  /// persist them on first encounter.
  Future<User?> signInWithApple() async {
    final appleProvider = AppleAuthProvider();
    // Request email and name scopes — required for account creation.
    appleProvider.addScope('email');
    appleProvider.addScope('name');

    // signInWithProvider handles the full OAuth flow natively.
    final result = await _auth.signInWithProvider(appleProvider);
    return result.user;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Sign Out
  // ─────────────────────────────────────────────────────────────────────────

  /// Signs the user out of both Firebase and the federated provider.
  ///
  /// Order matters:
  ///   1. Sign out of Google (if it was used) so the next sign-in shows the
  ///      account chooser instead of auto-selecting the previous account.
  ///   2. Sign out of Firebase to clear the local session token.
  ///
  /// After this call, [authStateChanges] emits `null`, triggering navigation
  /// back to the login screen via the auth state listener.
  Future<void> signOut() async {
    // Drop the cached offline profile, home cards, and territories so the next
    // user can't inherit this session on a later offline launch — profile/session
    // (#19), missions/exploration cards (#34), and own-hex territories (#33).
    await ProfileCache.clear();
    await GameStateCache.clear();
    await TerritoryCache.clear();
    await NotificationCache.clear(); // notification inbox is user-bound too (#30)
    // Only attempt Google sign-out if we previously initialized the SDK.
    if (_googleInitialized) {
      await GoogleSignIn.instance.signOut();
    }
    await _auth.signOut();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Riverpod Providers
// ─────────────────────────────────────────────────────────────────────────────

/// Provides a singleton [AuthService] instance for the entire app.
///
/// Because [AuthService] is stateless (aside from the [_googleInitialized]
/// flag), a simple `Provider` is sufficient — no disposal logic needed.
final authServiceProvider = Provider<AuthService>((ref) => AuthService());

/// Exposes the Firebase auth state as an async stream to the widget tree.
///
/// Widgets and other providers can `watch` this to reactively respond to
/// sign-in/sign-out events. Emits:
///   - A [User] object when the user is authenticated.
///   - `null` when the user is signed out.
final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authServiceProvider).authStateChanges;
});
