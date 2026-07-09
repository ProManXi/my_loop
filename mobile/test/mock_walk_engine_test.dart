/// Tests for the mock walk simulator engine (#29).
///
/// These lock in the properties that make a simulated walk survive the SAME server
/// anti-cheat the real app faces:
///   • bearing std-dev > 2°  (server rejects spoof-smooth lines),
///   • every hop under the max distance/speed cap,
///   • a loop route actually closes within the client closure threshold.
/// They also pin the failure mode (jitter off ⇒ straight line ⇒ would be rejected),
/// so the realism is a tested guarantee, not an accident.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:myloop/shared/constants/app_constants.dart';
import 'package:myloop/features/journey/loop_detector.dart';
import 'package:myloop/shared/services/mock/mock_walk_config.dart';
import 'package:myloop/shared/services/mock/mock_walk_engine.dart';

// Client-side thresholds: imported from the real symbols so they can't silently drift.
final double _closureThresholdMeters = LoopDetector.closureThresholdMeters;
final int _minLoopPoints = LoopDetector.minLoopPoints;

// Server-side (C#) thresholds the mock must satisfy. These live in AntiCheatConstants.cs
// and can't be imported into Dart, so they're duplicated here on purpose — a server
// tightening should break this test loudly.
const double _minBearingStdDev = 2.0; // AntiCheatConstants.MinBearingStdDev
const double _maxHopMeters = 60.0; // AntiCheatConstants.MaxDistanceBetweenPointsMeters

/// The real moving noise floor the journey controller applies to a mock fix (whose
/// speed is always > stationary threshold): clamp(accuracy, movingMin, movingMax).
final double _noiseFloorMeters = MockWalkConstants.reportedAccuracyMeters
    .clamp(AppConstants.movingNoiseFloorMin, AppConstants.movingNoiseFloorMax);

/// Mirrors the journey controller's noise-floor dedup: drop points closer than the
/// moving noise floor to the last kept point. This is the path the server actually sees.
List<LatLng> _retained(List<MockRoutePoint> raw) {
  final kept = <LatLng>[];
  for (final p in raw) {
    final here = LatLng(p.lat, p.lng);
    if (kept.isEmpty ||
        Geolocator.distanceBetween(kept.last.latitude, kept.last.longitude, here.latitude, here.longitude) >=
            _noiseFloorMeters) {
      kept.add(here);
    }
  }
  return kept;
}

/// Std-dev of consecutive bearing changes — the server's smoothness metric.
double _bearingChangeStdDev(List<LatLng> path) {
  if (path.length < 3) return 0;
  final changes = <double>[];
  for (var i = 2; i < path.length; i++) {
    final b1 = Geolocator.bearingBetween(
        path[i - 2].latitude, path[i - 2].longitude, path[i - 1].latitude, path[i - 1].longitude);
    final b2 = Geolocator.bearingBetween(
        path[i - 1].latitude, path[i - 1].longitude, path[i].latitude, path[i].longitude);
    var change = b2 - b1;
    while (change > 180) {
      change -= 360;
    }
    while (change < -180) {
      change += 360;
    }
    changes.add(change.abs());
  }
  final mean = changes.reduce((a, b) => a + b) / changes.length;
  final variance = changes.map((c) => (c - mean) * (c - mean)).reduce((a, b) => a + b) / changes.length;
  return sqrt(variance);
}

void main() {
  // Fixed seed so jitter is deterministic and assertions are stable.
  MockWalkEngine engine(MockWalkConfig c) => MockWalkEngine(c, random: Random(42));

  const start = LatLng(37.4220, -122.0841);

  group('loop route', () {
    final raw = engine(const MockWalkConfig(routeType: MockRouteType.loop, startPoint: start)).plotPoints();
    final kept = _retained(raw);

    test('produces enough retained points for a claimable loop', () {
      expect(kept.length, greaterThanOrEqualTo(_minLoopPoints));
    });

    test('closes within the loop closure threshold', () {
      final d = Geolocator.distanceBetween(
          kept.first.latitude, kept.first.longitude, kept.last.latitude, kept.last.longitude);
      expect(d, lessThanOrEqualTo(_closureThresholdMeters));
    });

    test('looks like a human walk: bearing std-dev exceeds the smoothness floor', () {
      expect(_bearingChangeStdDev(kept), greaterThan(_minBearingStdDev));
    });

    test('no hop exceeds the server distance cap', () {
      for (var i = 1; i < raw.length; i++) {
        final d = Geolocator.distanceBetween(raw[i - 1].lat, raw[i - 1].lng, raw[i].lat, raw[i].lng);
        expect(d, lessThan(_maxHopMeters), reason: 'hop $i = ${d}m');
      }
    });
  });

  group('straight route', () {
    test('with jitter still passes the smoothness floor', () {
      final kept = _retained(engine(const MockWalkConfig(
        routeType: MockRouteType.straight,
        startPoint: start,
      )).plotPoints());
      expect(_bearingChangeStdDev(kept), greaterThan(_minBearingStdDev));
    });

    test('WITHOUT jitter is a spoof-smooth line (documents why jitter is required)', () {
      final kept = _retained(engine(const MockWalkConfig(
        routeType: MockRouteType.straight,
        startPoint: start,
        jitterEnabled: false,
      )).plotPoints());
      expect(_bearingChangeStdDev(kept), lessThan(_minBearingStdDev));
    });
  });

  group('multi-waypoint route', () {
    const waypoints = [
      LatLng(37.4220, -122.0841),
      LatLng(37.4232, -122.0841),
      LatLng(37.4232, -122.0825),
    ];
    test('passes near each waypoint in order', () {
      final raw = engine(const MockWalkConfig(
        routeType: MockRouteType.multiWaypoint,
        waypoints: waypoints,
      )).plotPoints();
      for (final wp in waypoints) {
        final nearest = raw
            .map((p) => Geolocator.distanceBetween(p.lat, p.lng, wp.latitude, wp.longitude))
            .reduce(min);
        // Within jitter distance of the waypoint.
        expect(nearest, lessThan(3 * MockWalkConstants.jitterSigmaMeters));
      }
    });

    test('auto-close (default) walks back to the first waypoint so the loop can claim', () {
      final anchors = engine(const MockWalkConfig(
        routeType: MockRouteType.multiWaypoint,
        waypoints: waypoints,
      )).buildRouteAnchors();
      expect(anchors.last, waypoints.first);

      final kept = _retained(engine(const MockWalkConfig(
        routeType: MockRouteType.multiWaypoint,
        waypoints: waypoints,
      )).plotPoints());
      final d = Geolocator.distanceBetween(
          kept.first.latitude, kept.first.longitude, kept.last.latitude, kept.last.longitude);
      expect(d, lessThanOrEqualTo(_closureThresholdMeters));
    });

    test('autoCloseLoop: false leaves the tapped path open', () {
      final anchors = engine(const MockWalkConfig(
        routeType: MockRouteType.multiWaypoint,
        waypoints: waypoints,
        autoCloseLoop: false,
      )).buildRouteAnchors();
      expect(anchors.last, waypoints.last);
    });

    test('an already-closed tapped path is not double-closed', () {
      final anchors = engine(const MockWalkConfig(
        routeType: MockRouteType.multiWaypoint,
        waypoints: [...waypoints, LatLng(37.4220, -122.0841)],
      )).buildRouteAnchors();
      expect(anchors, hasLength(4));
    });
  });

  group('straight route bearing', () {
    test('bearing 90° heads east of the start point', () {
      final anchors = engine(const MockWalkConfig(
        routeType: MockRouteType.straight,
        startPoint: start,
        straightBearingDegrees: 90,
      )).buildRouteAnchors();
      expect(anchors.last.longitude, greaterThan(start.longitude));
      expect((anchors.last.latitude - start.latitude).abs(), lessThan(1e-4));
    });
  });

  group('distance parameterisation (runner contract)', () {
    final e = engine(const MockWalkConfig(
      routeType: MockRouteType.straight,
      startPoint: start,
    ));

    test('totalLengthMeters matches the configured route length', () {
      expect(e.totalLengthMeters,
          closeTo(MockWalkConstants.defaultStraightLengthMeters, 1.0));
    });

    test('cleanPointAt clamps to the route ends', () {
      expect(e.cleanPointAt(-10), e.buildRouteAnchors().first);
      expect(e.cleanPointAt(e.totalLengthMeters + 50), e.buildRouteAnchors().last);
    });

    test('cleanPointAt walks monotonically away from the start', () {
      final origin = e.buildRouteAnchors().first;
      double at(double m) => Geolocator.distanceBetween(origin.latitude,
          origin.longitude, e.cleanPointAt(m).latitude, e.cleanPointAt(m).longitude);
      expect(at(50), closeTo(50, 1.0));
      expect(at(150), closeTo(150, 1.0));
    });
  });

  group('slider extremes stay claimable', () {
    test('loop at minimum radius still yields >= minLoopPoints retained points', () {
      final kept = _retained(engine(const MockWalkConfig(
        routeType: MockRouteType.loop,
        startPoint: start,
        loopRadiusMeters: MockWalkConstants.minLoopRadiusMeters,
      )).plotPoints());
      expect(kept.length, greaterThanOrEqualTo(_minLoopPoints));
    });

    test('straight at minimum length yields >= minGpsPointsPerClaim retained points', () {
      final kept = _retained(engine(const MockWalkConfig(
        routeType: MockRouteType.straight,
        startPoint: start,
        straightLengthMeters: MockWalkConstants.minStraightLengthMeters,
      )).plotPoints());
      expect(kept.length, greaterThanOrEqualTo(AppConstants.minGpsPointsPerClaim));
    });

    test('copyWith clamps an out-of-range radius up to the minimum', () {
      const cfg = MockWalkConfig();
      expect(cfg.copyWith(loopRadiusMeters: 5).loopRadiusMeters,
          MockWalkConstants.minLoopRadiusMeters);
    });
  });

  group('engine memoization', () {
    test('repeated plotPoints calls return the identical (cached) list', () {
      final e = engine(const MockWalkConfig(routeType: MockRouteType.loop, startPoint: start));
      expect(identical(e.plotPoints(), e.plotPoints()), isTrue);
    });
  });

  group('generatePositions', () {
    final positions = engine(const MockWalkConfig(routeType: MockRouteType.loop, startPoint: start))
        .generatePositions(startTime: DateTime(2026, 1, 1));

    test('timestamps are strictly increasing', () {
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i].timestamp.isAfter(positions[i - 1].timestamp), isTrue);
      }
    });

    test('fixes are marked mocked and carry the configured speed', () {
      expect(positions.first.isMocked, isTrue);
      expect(positions.first.speed, MockWalkConstants.defaultSpeedMps);
    });
  });

  // Every one-tap quick-launch scenario must clear the SAME anti-cheat bar as a
  // hand-configured walk. This is the tested guarantee behind the "curated, small,
  // valid-by-construction" claim — a scenario added with bad tuning fails loudly here.
  group('quick-launch scenarios stay anti-cheat-valid by construction', () {
    // The server's per-hop batch gate (PathValidationService): a hop is a violation
    // only when its straight-line distance exceeds what max walking speed could cover
    // in the elapsed capturedAt time, PLUS a GPS-uncertainty margin. Mirrored here so
    // the assertion matches what the backend actually rejects (not a bare d/dt).
    const maxSpeedMps = 8.33; // AntiCheatConstants.MaxSpeedMetersPerSecond
    const gpsDriftMarginMeters = 30.0; // PathValidationService.gpsDriftMarginMeters

    for (final scenario in MockWalkScenarios.all) {
      group(scenario.label, () {
        final cfg = scenario.config.copyWith(startPoint: start);
        final kept = _retained(engine(cfg).plotPoints());

        test('has jitter enabled', () {
          expect(cfg.jitterEnabled, isTrue);
        });

        test('yields retained points above the relevant density floor', () {
          final floor = cfg.routeType == MockRouteType.loop
              ? _minLoopPoints
              : AppConstants.minGpsPointsPerClaim;
          expect(kept.length, greaterThanOrEqualTo(floor));
        });

        test('reads as a human walk (bearing std-dev over the floor)', () {
          expect(_bearingChangeStdDev(kept), greaterThan(_minBearingStdDev));
        });

        if (cfg.routeType == MockRouteType.loop) {
          test('loop closes within the closure threshold', () {
            final d = Geolocator.distanceBetween(kept.first.latitude,
                kept.first.longitude, kept.last.latitude, kept.last.longitude);
            expect(d, lessThanOrEqualTo(_closureThresholdMeters));
          });
        }

        // Model the real flow: fixes are stamped ~1/sec in wall-clock and the client
        // noise floor drops sub-floor hops, so retained capturedAt spacing ≈ tick
        // spacing. A brisk 4 m/s scenario must still keep every retained hop < cap.
        test('every retained hop stays under the server speed cap', () {
          final positions =
              engine(cfg).generatePositions(startTime: DateTime(2026, 1, 1));
          Position? last;
          for (final p in positions) {
            if (last == null) {
              last = p;
              continue;
            }
            final d = Geolocator.distanceBetween(
                last.latitude, last.longitude, p.latitude, p.longitude);
            if (d < _noiseFloorMeters) continue; // dropped by the client noise floor
            final dt = p.timestamp.difference(last.timestamp).inMilliseconds / 1000.0;
            expect(d, lessThanOrEqualTo(maxSpeedMps * dt + gpsDriftMarginMeters),
                reason: '${scenario.label}: ${d}m hop over ${dt}s exceeds the '
                    'server per-hop allowance');
            last = p;
          }
        });
      });
    }
  });
}
