/// MyLoop — Mock Walk Simulation: live run pacing + control (#160)
///
/// Paces a [MockWalkEngine] route in real wall-clock time and owns the mutable
/// run state (distance walked, paused, live speed). Replaces the engine's old
/// fire-and-forget stream so the debug overlay can pause/resume and re-pace a
/// walk mid-run WITHOUT touching [mockWalkConfigProvider] — a config write would
/// rebuild the location service and restart the walk from fix zero.
///
/// Anti-cheat honesty is preserved by construction:
///   • fixes are timestamped at emission, one per tick, so per-hop speed is real,
///   • pausing emits stationary jittered fixes (`speed: 0`) — a human standing
///     still — never a timestamp gap or a teleport,
///   • [setSpeedMps] clamps to the config bounds (max 4 m/s « the 8.33 m/s cap).
///
/// Every exit path (route completed, subscription cancelled, double-stop)
/// converges on the idempotent [_finish] — no timer leaks, no emit-after-close.
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'mock_walk_config.dart';
import 'mock_walk_engine.dart';
import 'mock_walk_run_state.dart';

class MockWalkRunner {
  final MockWalkEngine _engine;

  /// Optional, debug-only run-state sink for the dev HUD and its controls.
  /// The values it receives never feed back into the emitted stream.
  final MockWalkRunNotifier? _listener;

  final StreamController<Position> _controller;
  Timer? _timer;
  double _speedMps;
  double _walkedMeters = 0;
  bool _paused = false;
  bool _finished = false;
  MockRoutePoint? _lastFix;

  MockWalkRunner(this._engine, [this._listener])
      : _speedMps = _engine.config.speedMps,
        _controller = StreamController<Position>() {
    _controller.onListen = _begin;
    _controller.onCancel = _finish;
  }

  /// The simulated walk. Single-subscription; cancelling it ends the run.
  Stream<Position> get stream => _controller.stream;

  bool get isFinished => _finished;

  // ── Controls (idempotent; no-ops once finished) ───────────────────────────

  void pause() {
    if (_finished || _paused) return;
    _paused = true;
    _report();
  }

  void resume() {
    if (_finished || !_paused) return;
    _paused = false;
    _report();
  }

  void setSpeedMps(double value) {
    if (_finished) return;
    _speedMps = value.clamp(MockWalkConstants.minSpeedMps, MockWalkConstants.maxSpeedMps);
    _report();
  }

  // ── Run lifecycle ──────────────────────────────────────────────────────────

  void _begin() {
    _listener?.begin(totalMeters: _engine.totalLengthMeters, speedMps: _speedMps, runner: this);
    _emitFix(); // first fix immediately, like a real stream's initial position
    _timer = Timer.periodic(MockWalkConstants.tickInterval, (_) => _onTick());
  }

  void _onTick() {
    if (_finished) return;
    if (!_paused) {
      _walkedMeters =
          (_walkedMeters + _speedMps * MockWalkConstants.tickInterval.inMilliseconds / 1000.0)
              .clamp(0.0, _engine.totalLengthMeters);
    }
    _emitFix();
    if (!_paused && _walkedMeters >= _engine.totalLengthMeters) _finish();
  }

  /// Emits one jittered fix at the current route distance. While paused this is
  /// a stationary re-fix of the same clean point (`speed: 0`) — GPS wander
  /// around a standing human, which the journey's stationary noise floor dedups.
  void _emitFix() {
    final jittered = _engine.jitterPoint(_engine.cleanPointAt(_walkedMeters));
    final previous = _lastFix;
    final heading = previous == null
        ? 0.0
        : Geolocator.bearingBetween(previous.lat, previous.lng, jittered.latitude, jittered.longitude);
    final fix = MockRoutePoint(jittered.latitude, jittered.longitude, heading);
    _lastFix = fix;
    _controller.add(_engine.toPosition(fix, DateTime.now(), speedMps: _paused ? 0.0 : _speedMps));
    if (!_finished) {
      _listener?.reportFix(this,
          walkedMeters: _walkedMeters, paused: _paused, speedMps: _speedMps);
    }
  }

  void _report() {
    if (_finished) return;
    _listener?.reportControl(this,
        walkedMeters: _walkedMeters, paused: _paused, speedMps: _speedMps);
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    _listener?.finish(this);
    if (!_controller.isClosed) _controller.close();
  }
}
