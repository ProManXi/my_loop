/// Tests for the live mock-walk runner (#160): real-time pacing with mid-run
/// pause / resume / speed control, and idempotent teardown.
///
/// Uses [fakeAsync] so tick timers are driven deterministically. The invariants
/// guarded here are the ones the design doc calls out:
///   • pausing emits stationary `speed: 0` fixes (timestamps stay honest) and
///     stops route progress,
///   • a live speed change re-paces the remaining route and clamps to the
///     anti-cheat-safe bounds,
///   • every exit path (completion, cancel, double-cancel, stop-while-paused)
///     converges without leaked timers or emit-after-close.
library;

import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:myloop/shared/services/mock/mock_walk_config.dart';
import 'package:myloop/shared/services/mock/mock_walk_engine.dart';
import 'package:myloop/shared/services/mock/mock_walk_runner.dart';

// A 100 m straight route at max speed (4 m/s) finishes in 25 ticks — short
// enough to drive to completion under fakeAsync.
const _config = MockWalkConfig(
  enabled: true,
  routeType: MockRouteType.straight,
  startPoint: LatLng(37.4220, -122.0841),
  straightLengthMeters: MockWalkConstants.minStraightLengthMeters,
  speedMps: MockWalkConstants.maxSpeedMps,
);

// Seeded so jitter-based assertions are deterministic.
MockWalkRunner _runner() =>
    MockWalkRunner(MockWalkEngine(_config, random: Random(42)));

void main() {
  const tick = MockWalkConstants.tickInterval;

  test('emits the first fix immediately on listen, then one per tick', () {
    fakeAsync((async) {
      final runner = _runner();
      final fixes = <Position>[];
      runner.stream.listen(fixes.add);
      async.flushMicrotasks();
      expect(fixes, hasLength(1));

      async.elapse(tick * 3);
      expect(fixes, hasLength(4));
      expect(fixes.every((p) => p.isMocked), isTrue);
    });
  });

  test('completes the route and closes the stream', () {
    fakeAsync((async) {
      final runner = _runner();
      var done = false;
      runner.stream.listen((_) {}, onDone: () => done = true);
      async.flushMicrotasks();

      async.elapse(tick * 30); // > 25 ticks needed
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(runner.isFinished, isTrue);
    });
  });

  test('pause stops progress but keeps emitting stationary speed-0 fixes', () {
    fakeAsync((async) {
      final runner = _runner();
      final fixes = <Position>[];
      runner.stream.listen(fixes.add);
      async.flushMicrotasks();
      async.elapse(tick * 2);

      runner.pause();
      final atPause = fixes.length;
      async.elapse(tick * 5);

      // Fixes kept flowing while paused…
      expect(fixes.length, atPause + 5);
      final pausedFixes = fixes.sublist(atPause);
      expect(pausedFixes.every((p) => p.speed == 0), isTrue);
      // …timestamps stayed monotonic (fakeAsync does not fake DateTime.now(),
      // so only non-decreasing order can be asserted deterministically)…
      expect(pausedFixes.last.timestamp.isBefore(pausedFixes.first.timestamp), isFalse);
      // …and the walker stood still: paused fixes cluster around one point
      // (only jitter apart), instead of covering 5 ticks × 4 m/s = 20 m.
      final drift = Geolocator.distanceBetween(
        pausedFixes.first.latitude, pausedFixes.first.longitude,
        pausedFixes.last.latitude, pausedFixes.last.longitude,
      );
      expect(drift, lessThan(6 * MockWalkConstants.jitterSigmaMeters));
    });
  });

  test('resume continues from the paused distance (pause adds ticks, not meters)', () {
    fakeAsync((async) {
      // Without a pause the route takes 25 ticks; a 10-tick pause must push
      // completion out by exactly those 10 ticks.
      final runner = _runner();
      var done = false;
      runner.stream.listen((_) {}, onDone: () => done = true);
      async.flushMicrotasks();

      async.elapse(tick * 5);
      runner.pause();
      async.elapse(tick * 10);
      runner.resume();

      async.elapse(tick * 19); // 5 + 19 = 24 walking ticks < 25 needed
      expect(done, isFalse);
      async.elapse(tick * 2);
      async.flushMicrotasks();
      expect(done, isTrue);
    });
  });

  test('setSpeedMps clamps to the anti-cheat-safe bounds', () {
    fakeAsync((async) {
      final runner = _runner();
      final fixes = <Position>[];
      runner.stream.listen(fixes.add);
      async.flushMicrotasks();

      runner.setSpeedMps(99);
      async.elapse(tick);
      expect(fixes.last.speed, MockWalkConstants.maxSpeedMps);

      runner.setSpeedMps(0.01);
      async.elapse(tick);
      expect(fixes.last.speed, MockWalkConstants.minSpeedMps);
    });
  });

  test('slowing down mid-run re-paces the remaining route', () {
    fakeAsync((async) {
      final runner = _runner();
      var done = false;
      runner.stream.listen((_) {}, onDone: () => done = true);
      async.flushMicrotasks();

      async.elapse(tick * 10); // 40 m walked, 60 m left
      runner.setSpeedMps(MockWalkConstants.minSpeedMps); // 0.5 m/s → 120 more ticks
      async.elapse(tick * 100);
      expect(done, isFalse);
      async.elapse(tick * 25);
      async.flushMicrotasks();
      expect(done, isTrue);
    });
  });

  test('cancelling the subscription finishes the run; controls become no-ops', () {
    fakeAsync((async) {
      final runner = _runner();
      final sub = runner.stream.listen((_) {});
      async.flushMicrotasks();
      async.elapse(tick * 3);

      sub.cancel();
      async.flushMicrotasks();
      expect(runner.isFinished, isTrue);

      // None of these may throw or restart anything after teardown.
      runner.pause();
      runner.resume();
      runner.setSpeedMps(2.0);
      sub.cancel(); // double-cancel
      async.elapse(tick * 5);
      expect(runner.isFinished, isTrue);
    });
  });

  test('cancelling while paused tears down cleanly', () {
    fakeAsync((async) {
      final runner = _runner();
      final sub = runner.stream.listen((_) {});
      async.flushMicrotasks();
      async.elapse(tick * 2);
      runner.pause();

      sub.cancel();
      async.flushMicrotasks();
      expect(runner.isFinished, isTrue);
      async.elapse(tick * 5); // no pending timers may fire into a closed sink
    });
  });
}
