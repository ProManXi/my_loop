/// Journey controller — manages GPS tracking state during a walk.
///
/// Uses Riverpod's [Notifier] pattern to expose reactive [JourneyState].
/// Detects loops in real-time and fetches hex previews from the API.
library;

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';
import 'package:myloop/shared/constants/app_constants.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/batch_drain_service.dart';
import 'package:myloop/shared/services/location_service.dart';
import 'package:myloop/shared/services/step_claim_queue.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/features/journey/loop_detector.dart';

// ──────────────────────────────────────────────────────────────────────────────
// State
// ──────────────────────────────────────────────────────────────────────────────

enum JourneyStatus { idle, tracking, submitting }

/// Minimal metadata for each step-claimed hex during a walk.
class StepClaimMeta {
  final int cellId;
  final List<List<double>> boundary;
  final bool wasStolen;
  const StepClaimMeta({required this.cellId, required this.boundary, required this.wasStolen});
}

class JourneyState {
  final JourneyStatus status;
  final List<List<double>> path;
  final double distanceMeters;
  final Duration elapsed;
  final Position? currentPosition;
  final String? error;
  final List<List<List<double>>> previewBoundaries;
  final int loopCount;
  /// Hex boundaries claimed in real-time during this walk (walk-through claiming).
  final List<List<List<double>>> claimedHexBoundaries;
  /// Running count of hexes claimed this walk.
  final int claimedCount;
  /// Last stolen hex info for UI feedback.
  final String? lastStolenFrom;
  /// Total XP gained during this walk.
  final int xpGainedThisWalk;
  /// Non-null if a level-up just happened (the new level number).
  final int? levelUpTo;
  /// Last achievement unlocked (for toast notification).
  final String? achievementUnlocked;
  /// Metadata for each step-claimed hex (for hex manager integration).
  final List<StepClaimMeta> claimedMeta;
  /// Running count of batches permanently rejected this walk (e.g. anti-cheat
  /// speed/smoothness violations). Surfaced in the debug mock-walk summary so a
  /// desk tester sees rejections without digging through logs; harmless in prod.
  final int rejectionCount;

  const JourneyState({
    this.status = JourneyStatus.idle,
    this.path = const [],
    this.distanceMeters = 0,
    this.elapsed = Duration.zero,
    this.currentPosition,
    this.error,
    this.previewBoundaries = const [],
    this.loopCount = 0,
    this.claimedHexBoundaries = const [],
    this.claimedCount = 0,
    this.lastStolenFrom,
    this.xpGainedThisWalk = 0,
    this.levelUpTo,
    this.achievementUnlocked,
    this.claimedMeta = const [],
    this.rejectionCount = 0,
  });

  JourneyState copyWith({
    JourneyStatus? status,
    List<List<double>>? path,
    double? distanceMeters,
    Duration? elapsed,
    Position? currentPosition,
    String? error,
    List<List<List<double>>>? previewBoundaries,
    int? loopCount,
    List<List<List<double>>>? claimedHexBoundaries,
    int? claimedCount,
    String? lastStolenFrom,
    int? xpGainedThisWalk,
    int? levelUpTo,
    String? achievementUnlocked,
    List<StepClaimMeta>? claimedMeta,
    int? rejectionCount,
  }) {
    return JourneyState(
      status: status ?? this.status,
      path: path ?? this.path,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      elapsed: elapsed ?? this.elapsed,
      currentPosition: currentPosition ?? this.currentPosition,
      error: error,
      previewBoundaries: previewBoundaries ?? this.previewBoundaries,
      loopCount: loopCount ?? this.loopCount,
      claimedHexBoundaries: claimedHexBoundaries ?? this.claimedHexBoundaries,
      claimedCount: claimedCount ?? this.claimedCount,
      lastStolenFrom: lastStolenFrom ?? this.lastStolenFrom,
      xpGainedThisWalk: xpGainedThisWalk ?? this.xpGainedThisWalk,
      levelUpTo: levelUpTo,
      achievementUnlocked: achievementUnlocked,
      claimedMeta: claimedMeta ?? this.claimedMeta,
      rejectionCount: rejectionCount ?? this.rejectionCount,
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Controller
// ──────────────────────────────────────────────────────────────────────────────

class JourneyController extends Notifier<JourneyState> {
  StreamSubscription<Position>? _positionSub;
  Timer? _timer;
  DateTime? _startTime;
  int _lastLoopCount = 0;
  bool _previewInFlight = false;
  int _pointsSinceLastCheck = 0;
  List<List<double>>? _pendingPreviewPath;

  /// Id for the current walk. Stamped on every queued GPS point and sent with the final
  /// loop claim so the server records the whole walk as one Claim (#56). Generated fresh
  /// in [startJourney]; read by the journey screen before [stopJourney] for the loop claim.
  String? _walkSessionId;
  String? get walkSessionId => _walkSessionId;

  static const int _loopCheckInterval = 5;

  @override
  JourneyState build() => const JourneyState();

  Future<void> startJourney() async {
    final locationService = ref.read(locationServiceProvider);

    // A journey is meaningless offline: hex capture is server-validated and the
    // user would see no preview, no claims, and no feedback. Block at the start
    // and tell them why (issue #35). Mid-journey drops are still tolerated by
    // the persisted step-claim queue, which drains on reconnect.
    final api = ref.read(apiServiceProvider);
    if (!await api.isServerReachable()) {
      state = state.copyWith(error: AppConstants.offlineStartJourneyMessage);
      return;
    }

    try {
      final hasPermission = await locationService.requestPermission();
      if (!hasPermission) {
        state = state.copyWith(error: 'Location permission denied. Please allow location access.');
        return;
      }

      final pos = await locationService.getCurrentPosition();
      _startTime = DateTime.now();
      // New walk → new session id; every point and the loop claim carry it (#56).
      _walkSessionId = const Uuid().v4();

      state = state.copyWith(
        status: JourneyStatus.tracking,
        path: [[pos.latitude, pos.longitude]],
        currentPosition: pos,
        distanceMeters: 0,
        elapsed: Duration.zero,
        error: null,
        rejectionCount: 0,
      );

      await _initWriteLayer();
      _positionSub = locationService.startTracking().listen(_onPosition);
      _startElapsedTimer();
    } catch (e) {
      state = state.copyWith(error: e.toString().replaceFirst('Exception: ', ''));
    }
  }

  List<List<double>> stopJourney() {
    _positionSub?.cancel();
    _timer?.cancel();
    _disposeWriteLayer();
    _resetTrackingState();
    final path = state.path;
    state = state.copyWith(
      status: JourneyStatus.idle,
      path: const [],
      previewBoundaries: const [],
      claimedHexBoundaries: const [],
      claimedCount: 0,
      loopCount: 0,
      claimedMeta: const [],
    );
    return path;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // GPS position handling
  // ────────────────────────────────────────────────────────────────────────────

  void _onPosition(Position pos) {
    if (pos.accuracy > AppConstants.maxAccuracyMeters) {
      state = state.copyWith(currentPosition: pos);
      return;
    }

    final distanceFromLast = _distanceFromLastPoint(pos);
    final noiseFloor = _calculateNoiseFloor(pos);

    if (distanceFromLast < noiseFloor && state.path.isNotEmpty) {
      state = state.copyWith(currentPosition: pos);
      return;
    }

    final updatedPath = [...state.path, [pos.latitude, pos.longitude]];
    state = state.copyWith(
      path: updatedPath,
      currentPosition: pos,
      distanceMeters: state.distanceMeters + distanceFromLast,
    );

    _enqueueStep(pos.latitude, pos.longitude);
    _throttledLoopCheck(updatedPath);
  }

  double _distanceFromLastPoint(Position pos) {
    if (state.path.isEmpty) return 0;
    final last = state.path.last;
    return Geolocator.distanceBetween(last[0], last[1], pos.latitude, pos.longitude);
  }

  double _calculateNoiseFloor(Position pos) {
    if (state.path.isEmpty) return 0.0;

    final isStationary = pos.speed >= 0 && pos.speed < AppConstants.stationarySpeedThreshold;

    if (isStationary) {
      return pos.accuracy.clamp(
        AppConstants.stationaryNoiseFloorMin,
        AppConstants.stationaryNoiseFloorMax,
      );
    }
    return pos.accuracy.clamp(
      AppConstants.movingNoiseFloorMin,
      AppConstants.movingNoiseFloorMax,
    );
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Write-Ahead Log + Batch Drain — resilient step claiming
  // ────────────────────────────────────────────────────────────────────────────

  StepClaimQueue? _queue;
  BatchDrainService? _drainService;
  StreamSubscription<BatchResult>? _drainSub;
  StreamSubscription<String>? _rejectionSub;

  /// Initialize the persistent queue and drain service for this walk.
  Future<void> _initWriteLayer() async {
    final userId = ref.read(userProfileProvider).userId;
    if (userId == null) return;

    _queue = StepClaimQueue();
    await _queue!.init(userId);

    final api = ref.read(apiServiceProvider);
    _drainService = BatchDrainService(
      queue: _queue!,
      api: api,
      userId: userId,
    );

    // Listen for batch results to update UI in real-time
    _drainSub = _drainService!.onBatchResult.listen(_onBatchResult);
    // Surface permanent rejections (e.g. anti-cheat speed violation) to the user
    // instead of silently dropping the batch (MEDIUM-5).
    _rejectionSub = _drainService!.onRejection.listen((message) {
      state = state.copyWith(
        error: message,
        rejectionCount: state.rejectionCount + 1,
      );
    });
    _drainService!.start();
  }

  /// Enqueue a GPS point into the persistent WAL (instant, disk-backed).
  Future<void> _enqueueStep(double lat, double lng) async {
    if (_queue == null) return;

    final point = QueuedStepPoint(
      clientId: '${DateTime.now().millisecondsSinceEpoch}_${lat.toStringAsFixed(6)}',
      lat: lat,
      lng: lng,
      capturedAt: DateTime.now(),
      walkSessionId: _walkSessionId ?? '',
    );

    await _queue!.enqueue(point);
    _drainService?.notifyEnqueue();
  }

  /// Handle batch results from the drain service — update journey state.
  void _onBatchResult(BatchResult result) {
    if (state.status != JourneyStatus.tracking) return;

    final newBoundaries = <List<List<double>>>[];
    final newMeta = <StepClaimMeta>[];
    String? lastStolen;

    for (final r in result.results) {
      if (r.claimed && r.boundary != null) {
        newBoundaries.add(r.boundary!);
        newMeta.add(StepClaimMeta(
          cellId: r.cellId ?? 0,
          boundary: r.boundary!,
          wasStolen: r.wasStolen,
        ));
        if (r.wasStolen) lastStolen = r.previousOwnerName;
      }
    }

    if (newBoundaries.isEmpty) return;

    final achievementName = result.achievements.isNotEmpty
        ? '${result.achievements.first.icon} ${result.achievements.first.name}'
        : null;

    state = state.copyWith(
      claimedHexBoundaries: [...state.claimedHexBoundaries, ...newBoundaries],
      claimedCount: state.claimedCount + newBoundaries.length,
      claimedMeta: [...state.claimedMeta, ...newMeta],
      lastStolenFrom: lastStolen,
      xpGainedThisWalk: state.xpGainedThisWalk + result.xp.xpGained,
      levelUpTo: result.xp.leveledUp ? result.xp.level : null,
      achievementUnlocked: achievementName,
    );
  }

  /// Drain all remaining points before showing capture celebration.
  /// Returns true if successful, false if some points remain (network down).
  Future<bool> drainBeforeCapture() async {
    if (_drainService == null) return true;
    return await _drainService!.drainNow();
  }

  /// Number of points pending in queue (for UI indicator).
  int get pendingQueueSize => _queue?.length ?? 0;

  void _disposeWriteLayer() {
    _drainSub?.cancel();
    _rejectionSub?.cancel();
    _drainService?.dispose();
    _drainService = null;
    _drainSub = null;
    _rejectionSub = null;
    // Keep _queue alive — points persist on disk for next app launch
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Loop detection & preview
  // ────────────────────────────────────────────────────────────────────────────

  void _throttledLoopCheck(List<List<double>> path) {
    _pointsSinceLastCheck++;
    if (_pointsSinceLastCheck < _loopCheckInterval) return;
    _pointsSinceLastCheck = 0;

    // The client closure check is only a TRIGGER for the server preview, not
    // the displayed count: the server returns the authoritative, area-validated
    // and de-duplicated loopCount, which avoids the over-count this used to
    // show live (issue #21). state.loopCount is set only from the preview.
    final estimate = LoopDetector.countLoops(path);
    if (estimate != _lastLoopCount) {
      _lastLoopCount = estimate;
      if (estimate > 0) {
        _fetchPreview(List.from(path));
      }
    }
  }

  Future<void> _fetchPreview(List<List<double>> path) async {
    if (_previewInFlight) {
      _pendingPreviewPath = path;
      return;
    }
    _previewInFlight = true;
    _pendingPreviewPath = null;

    try {
      final api = ref.read(apiServiceProvider);
      // Cap path to avoid sending huge payloads — server enforces same limit
      final cappedPath = path.length > AppConstants.maxPreviewPathPoints
          ? path.sublist(path.length - AppConstants.maxPreviewPathPoints)
          : path;
      final preview = await api.previewClaim(path: cappedPath);
      if (state.status == JourneyStatus.tracking) {
        // The server's loop count is authoritative (area-validated +
        // de-duplicated), so it overrides the client's raw closure estimate
        // shown live during the walk (issue #21).
        state = state.copyWith(
          previewBoundaries: preview.boundaries,
          loopCount: preview.loopCount,
        );
      }
    } catch (_) {
      // Preview is best-effort
    } finally {
      _previewInFlight = false;
      final pending = _pendingPreviewPath;
      if (pending != null) {
        _pendingPreviewPath = null;
        _fetchPreview(pending);
      }
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Utilities
  // ────────────────────────────────────────────────────────────────────────────

  void _startElapsedTimer() {
    _timer = Timer.periodic(
      const Duration(seconds: AppConstants.timerIntervalSeconds),
      (_) {
        if (_startTime != null) {
          state = state.copyWith(elapsed: DateTime.now().difference(_startTime!));
        }
      },
    );
  }

  void _resetTrackingState() {
    _lastLoopCount = 0;
    _previewInFlight = false;
    _pointsSinceLastCheck = 0;
    _pendingPreviewPath = null;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Provider
// ──────────────────────────────────────────────────────────────────────────────

final journeyControllerProvider =
    NotifierProvider<JourneyController, JourneyState>(JourneyController.new);
