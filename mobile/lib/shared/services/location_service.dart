/// MyLoop — Location Service
///
/// Provides a unified interface for GPS location operations including
/// permission handling, one-shot position retrieval, and continuous
/// position streaming.
///
/// Continuous tracking is configured to keep delivering positions while the
/// app is backgrounded / the screen is off (issue #20): on Android via a
/// foreground service, on iOS via background location updates. Without this the
/// OS suspends the position stream when the app leaves the foreground, and the
/// walked path collapses to a straight line with its hexes lost.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:logging/logging.dart';
import 'package:myloop/shared/constants/app_constants.dart';
import 'package:myloop/shared/services/mock/mock_location_service.dart';
import 'package:myloop/shared/services/mock/mock_walk_config.dart';
import 'package:myloop/shared/services/mock/mock_walk_run_state.dart';

final _log = Logger('LocationService');

/// The platforms whose background-tracking behaviour differs. Passed explicitly
/// to [buildTrackingSettings] so the settings selection is unit-testable
/// without a real platform.
enum LocationPlatform { android, ios, other }

/// Resolves the current runtime platform for tracking-settings selection. Web
/// is always [LocationPlatform.other] (no background concept), and the
/// `dart:io` `Platform` checks are only reached off-web so they never run in a
/// browser.
LocationPlatform currentLocationPlatform() {
  if (kIsWeb) return LocationPlatform.other;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return LocationPlatform.android;
    case TargetPlatform.iOS:
      return LocationPlatform.ios;
    default:
      return LocationPlatform.other;
  }
}

/// Builds the [LocationSettings] used for continuous tracking on [platform].
///
/// - Android: [AndroidSettings] with a `foregroundNotificationConfig`, which
///   makes geolocator run a foreground service so location keeps streaming with
///   the screen off (issue #20).
/// - iOS: [AppleSettings] with background location updates enabled and
///   auto-pause disabled, so updates continue when the app is minimised.
/// - Other (web/desktop): plain [LocationSettings] — unchanged foreground
///   behaviour, no background concept.
///
/// Pure and side-effect free so it can be unit-tested per platform.
@visibleForTesting
LocationSettings buildTrackingSettings(LocationPlatform platform) {
  const accuracy = LocationAccuracy.high;
  const distanceFilter = AppConstants.gpsDistanceFilterMeters;

  switch (platform) {
    case LocationPlatform.android:
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'MyLoop is tracking your walk',
          notificationText: 'Recording your path to capture territory.',
          enableWakeLock: true,
        ),
      );
    case LocationPlatform.ios:
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        allowBackgroundLocationUpdates: true,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
      );
    case LocationPlatform.other:
      return const LocationSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
      );
  }
}

/// Encapsulates all GPS interactions for the MyLoop application.
class LocationService {
  StreamSubscription<Position>? _subscription;

  /// Checks that location services are enabled and requests user permission.
  /// Returns `true` when permission is granted.
  Future<bool> requestPermission() async {
    // On web, isLocationServiceEnabled may not work reliably
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled. Please enable GPS.');
      }
    } catch (e) {
      // On web browsers, this check may throw — proceed to permission request
      if (e is Exception && e.toString().contains('disabled')) rethrow;
    }

    // Check and request permission
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permission denied. Please allow location access in settings.');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      // Open app settings so the user can grant permission manually
      await Geolocator.openAppSettings();
      throw Exception('Location permanently denied. Please enable location in your device settings, then try again.');
    }

    // Background tracking (issue #20) needs all-the-time access. "While in use"
    // still lets foreground tracking work, but background delivery may be
    // throttled/stopped by the OS — surface that rather than failing silently.
    if (permission == LocationPermission.whileInUse) {
      _log.warning(
          'Location granted "while in use" only — background walk tracking may '
          'be limited until the user allows all-the-time access.');
    } else {
      _log.info('Location permission granted: $permission');
    }

    return true;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // One-Shot Position
  // ─────────────────────────────────────────────────────────────────────────

  /// Gets the current GPS position (single reading, high accuracy).
  Future<Position> getCurrentPosition() async {
    return await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: AppConstants.gpsTimeoutSeconds),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Continuous Tracking
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns a stream of position updates for continuous tracking.
  ///
  /// Uses platform-appropriate settings so updates keep arriving with the
  /// screen off (issue #20). Only emits when the user moves at least
  /// [AppConstants.gpsDistanceFilterMeters] meters.
  Stream<Position> startTracking() {
    final settings = buildTrackingSettings(currentLocationPlatform());
    _log.info('Starting background-capable tracking (${settings.runtimeType}).');
    return Geolocator.getPositionStream(locationSettings: settings);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Cleanup
  // ─────────────────────────────────────────────────────────────────────────

  /// Cancels any active position stream subscription.
  void dispose() {
    _subscription?.cancel();
  }
}

/// Provides the active [LocationService] — the real GPS service in normal use, or
/// the injectable [MockLocationService] when the mock walk simulator is enabled in a
/// debug build (#29). The `kDebugMode` guard makes the mock impossible to reach in a
/// release build. Everything downstream (journey controller, WAL queue, batch drain,
/// anti-cheat, DB) is identical for both — that is the point of injecting here.
final locationServiceProvider = Provider<LocationService>((ref) {
  if (kDebugMode) {
    final mockConfig = ref.watch(mockWalkConfigProvider);
    if (mockConfig.enabled) {
      return MockLocationService(
        mockConfig,
        ref.read(mockWalkRunProvider.notifier),
      );
    }
  }
  final service = LocationService();
  ref.onDispose(() => service.dispose());
  return service;
});
