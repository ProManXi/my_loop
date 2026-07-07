/// Tests for the mock-walk run-state notifier (#160) — the HUD's telemetry
/// source AND its control bridge to the live runner.
///
/// Guards the graceful-failure contract: control taps with no live run are
/// safe no-ops, a stale runner reporting or finishing late cannot clobber a
/// newer run (identity-guarded), and reporting after finish is ignored.
library;

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:myloop/shared/services/mock/mock_walk_config.dart';
import 'package:myloop/shared/services/mock/mock_walk_engine.dart';
import 'package:myloop/shared/services/mock/mock_walk_run_state.dart';
import 'package:myloop/shared/services/mock/mock_walk_runner.dart';

const _config = MockWalkConfig(
  enabled: true,
  routeType: MockRouteType.straight,
  startPoint: LatLng(37.4220, -122.0841),
);

MockWalkRunner _detachedRunner() =>
    MockWalkRunner(MockWalkEngine(_config, random: Random(1)));

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  MockWalkRunNotifier notifier() => container.read(mockWalkRunProvider.notifier);
  MockWalkRunState state() => container.read(mockWalkRunProvider);

  test('starts idle: inactive, zero fraction', () {
    expect(state().isActive, isFalse);
    expect(state().fraction, 0);
    expect(state().eta, Duration.zero);
  });

  test('begin resets a previous run and records the total', () {
    final first = _detachedRunner();
    notifier().begin(totalMeters: 200, speedMps: 2.0, runner: first);
    notifier().reportFix(first, walkedMeters: 50, paused: false, speedMps: 2.0);
    expect(state().emitted, 1);

    notifier().begin(totalMeters: 300, speedMps: 1.0, runner: _detachedRunner());
    expect(state().totalMeters, 300);
    expect(state().walkedMeters, 0);
    expect(state().emitted, 0);
    expect(state().finished, isFalse);
  });

  test('fixes count toward emitted; control reports do not', () {
    final runner = _detachedRunner();
    notifier().begin(totalMeters: 200, speedMps: 2.0, runner: runner);
    notifier().reportFix(runner, walkedMeters: 2, paused: false, speedMps: 2.0);
    notifier().reportControl(runner, walkedMeters: 2, paused: true, speedMps: 2.0);
    notifier().reportControl(runner, walkedMeters: 2, paused: true, speedMps: 3.0);

    expect(state().emitted, 1);
    expect(state().paused, isTrue);
    expect(state().speedMps, 3.0);
  });

  test('fraction and eta are distance-based at the current speed', () {
    final runner = _detachedRunner();
    notifier().begin(totalMeters: 200, speedMps: 2.0, runner: runner);
    notifier().reportFix(runner, walkedMeters: 50, paused: false, speedMps: 2.0);

    expect(state().fraction, 0.25);
    expect(state().eta, const Duration(seconds: 75)); // 150 m left at 2 m/s
  });

  test('reports after finish are ignored (a late tick cannot resurrect the HUD)', () {
    final runner = _detachedRunner();
    notifier().begin(totalMeters: 200, speedMps: 2.0, runner: runner);
    notifier().finish(runner);
    notifier().reportFix(runner, walkedMeters: 100, paused: false, speedMps: 2.0);

    expect(state().finished, isTrue);
    expect(state().walkedMeters, 0);
    expect(state().emitted, 0);
  });

  test('controls with no live runner are safe no-ops', () {
    expect(() {
      notifier().pause();
      notifier().resume();
      notifier().setSpeedMps(3.0);
    }, returnsNormally);
  });

  test('a stale runner reporting or finishing late cannot touch the newer run', () {
    final stale = _detachedRunner();
    notifier().begin(totalMeters: 100, speedMps: 2.0, runner: stale);

    final fresh = _detachedRunner();
    notifier().begin(totalMeters: 100, speedMps: 2.0, runner: fresh);

    // Late ticks and teardown from the leaked old runner — all ignored.
    notifier().reportFix(stale, walkedMeters: 99, paused: false, speedMps: 4.0);
    notifier().finish(stale);
    expect(state().walkedMeters, 0);
    expect(state().finished, isFalse);

    // The live runner still reports and finishes normally.
    notifier().reportFix(fresh, walkedMeters: 10, paused: false, speedMps: 2.0);
    expect(state().walkedMeters, 10);
    notifier().finish(fresh);
    expect(state().finished, isTrue);
  });

  test('reset returns to idle and drops the runner', () {
    notifier().begin(totalMeters: 100, speedMps: 2.0, runner: _detachedRunner());
    notifier().reset();
    expect(state().isActive, isFalse);
    expect(() => notifier().pause(), returnsNormally);
  });
}
