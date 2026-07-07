/// MyLoop — Mock Walk Simulation: injectable location source (#29, #160)
///
/// A drop-in stand-in for [LocationService] that feeds the simulated walk into the
/// exact same journey flow a real walk uses (loop detection → WAL queue → batch
/// drain → server anti-cheat → DB → SignalR). It `implements` the real service's
/// public surface, so the analyzer fails the build if that contract drifts.
///
/// Live pacing and mid-run control (pause / resume / speed) belong to the
/// [MockWalkRunner] this service creates per [startTracking]; the runner attaches
/// itself to the run-state notifier so the debug HUD can reach it.
///
/// Only ever constructed by `locationServiceProvider` under `kDebugMode` while the
/// simulator is enabled — unreachable in release builds.
library;

import 'package:geolocator/geolocator.dart';

import '../location_service.dart';
import 'mock_walk_config.dart';
import 'mock_walk_engine.dart';
import 'mock_walk_run_state.dart';
import 'mock_walk_runner.dart';

class MockLocationService implements LocationService {
  final MockWalkEngine _engine;

  /// Optional, debug-only run-state sink + control bridge for the dev HUD.
  /// Null in any path that does not surface progress (e.g. unit tests).
  final MockWalkRunNotifier? _runState;

  MockLocationService(MockWalkConfig config, [this._runState])
      : _engine = MockWalkEngine(config);

  /// The simulator never needs real OS permission.
  @override
  Future<bool> requestPermission() async => true;

  /// One-shot fix = a jittered fix at the route's start (distance zero).
  @override
  Future<Position> getCurrentPosition() async {
    final start = _engine.jitterPoint(_engine.cleanPointAt(0));
    return _engine.toPosition(
      MockRoutePoint(start.latitude, start.longitude, 0.0),
      DateTime.now(),
      speedMps: _engine.config.speedMps,
    );
  }

  /// Streams the simulated walk via a fresh [MockWalkRunner]. The journey
  /// controller owns the returned subscription; cancelling it ends the run.
  @override
  Stream<Position> startTracking() => MockWalkRunner(_engine, _runState).stream;

  /// No OS resources to release — the runner tears itself down when the journey
  /// controller cancels the stream subscription returned by [startTracking].
  @override
  void dispose() {}
}
