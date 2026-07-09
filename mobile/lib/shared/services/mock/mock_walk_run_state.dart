/// MyLoop — Mock Walk Simulation: live run state + control passthrough (#160)
///
/// Debug-only telemetry AND control surface for an in-flight simulated walk.
/// [MockWalkRunner] reports `begin` (attaching itself), a `reportTick` per
/// emitted fix, and `finish` (detaching); the dev HUD reads this state and its
/// pause / resume / speed buttons forward to the attached runner — no-ops when
/// no run is live, so a stale overlay tap can never crash.
///
/// Progress is distance-based (metres walked of total) because live speed
/// changes make fix counts meaningless for ETA. Telemetry NEVER feeds back into
/// the position stream or `capturedAt`; the real [LocationService] never touches
/// this, and nothing reads or writes it outside `kDebugMode`-gated code, so it
/// is inert in release.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mock_walk_runner.dart';

/// Immutable snapshot of a simulated walk's run state.
class MockWalkRunState {
  /// Full route length for this run, in metres (0 = no run started yet).
  final double totalMeters;

  /// Distance walked so far, in metres. Always `<= totalMeters`.
  final double walkedMeters;

  /// Fixes emitted so far (raw, before the journey's noise-floor dedup).
  final int emitted;

  /// Wall-clock start of the run, used to compute elapsed time.
  final DateTime? startedAt;

  /// True once the run has ended (route completed or subscription cancelled).
  final bool finished;

  /// True while the walker is standing still (stationary fixes keep emitting).
  final bool paused;

  /// The live walking speed, m/s. Tracks [MockWalkRunner.setSpeedMps].
  final double speedMps;

  const MockWalkRunState({
    this.totalMeters = 0,
    this.walkedMeters = 0,
    this.emitted = 0,
    this.startedAt,
    this.finished = false,
    this.paused = false,
    this.speedMps = 0,
  });

  /// True once a run has begun (whether or not it has ended).
  bool get isActive => totalMeters > 0;

  /// Completion fraction in `[0, 1]`.
  double get fraction => totalMeters == 0 ? 0 : (walkedMeters / totalMeters).clamp(0.0, 1.0);

  /// Time since the run started, or [Duration.zero] before it began.
  Duration get elapsed =>
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  /// Estimated time remaining at the CURRENT speed (what the walk would take if
  /// resumed/continued right now). Zero once finished or before a run starts.
  Duration get eta {
    if (!isActive || finished || speedMps <= 0) return Duration.zero;
    return Duration(seconds: ((totalMeters - walkedMeters) / speedMps).ceil());
  }
}

/// Holds the active run's state and forwards HUD control taps to the live
/// runner. Reset at the start of each run so a previous walk's totals can never
/// leak into the next one's HUD/ETA.
class MockWalkRunNotifier extends Notifier<MockWalkRunState> {
  MockWalkRunner? _runner;

  @override
  MockWalkRunState build() {
    // Hot restart / provider teardown: never keep forwarding to a dead runner.
    ref.onDispose(() => _runner = null);
    return const MockWalkRunState();
  }

  // ── Reporting (called by MockWalkRunner) ───────────────────────────────────

  /// Start a new run, attaching its [runner] as the control target.
  void begin({required double totalMeters, required double speedMps, required MockWalkRunner runner}) {
    _runner = runner;
    state = MockWalkRunState(
      totalMeters: totalMeters,
      startedAt: DateTime.now(),
      speedMps: speedMps,
    );
  }

  /// Record one emitted fix. Identity-guarded like [finish]: a leaked stale
  /// runner ticking late must not flip-flop a newer run's HUD.
  void reportFix(MockWalkRunner runner,
          {required double walkedMeters, required bool paused, required double speedMps}) =>
      _update(runner, walkedMeters: walkedMeters, paused: paused, speedMps: speedMps, emittedDelta: 1);

  /// Record a pause/resume/speed change (no fix emitted).
  void reportControl(MockWalkRunner runner,
          {required double walkedMeters, required bool paused, required double speedMps}) =>
      _update(runner, walkedMeters: walkedMeters, paused: paused, speedMps: speedMps, emittedDelta: 0);

  void _update(
    MockWalkRunner runner, {
    required double walkedMeters,
    required bool paused,
    required double speedMps,
    required int emittedDelta,
  }) {
    if (!identical(_runner, runner) || state.finished) return;
    state = MockWalkRunState(
      totalMeters: state.totalMeters,
      walkedMeters: walkedMeters,
      emitted: state.emitted + emittedDelta,
      startedAt: state.startedAt,
      paused: paused,
      speedMps: speedMps,
    );
  }

  /// Mark the run complete and detach [runner]. Guarded by identity: a stale
  /// runner finishing late must neither clobber a newer run's attachment nor
  /// mark the newer run's HUD as finished.
  void finish(MockWalkRunner runner) {
    if (!identical(_runner, runner)) return;
    _runner = null;
    state = MockWalkRunState(
      totalMeters: state.totalMeters,
      walkedMeters: state.walkedMeters,
      emitted: state.emitted,
      startedAt: state.startedAt,
      finished: true,
      paused: false,
      speedMps: state.speedMps,
    );
  }

  /// Return to the idle, no-run state.
  void reset() {
    _runner = null;
    state = const MockWalkRunState();
  }

  // ── Controls (HUD → live runner; safe no-ops when none) ───────────────────

  void pause() => _runner?.pause();

  void resume() => _runner?.resume();

  void setSpeedMps(double value) => _runner?.setSpeedMps(value);
}

final mockWalkRunProvider =
    NotifierProvider<MockWalkRunNotifier, MockWalkRunState>(MockWalkRunNotifier.new);
