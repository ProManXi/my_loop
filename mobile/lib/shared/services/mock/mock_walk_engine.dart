/// MyLoop — Mock Walk Simulation: engine (#29, reworked for #160)
///
/// Pure route geometry for the simulator. Turns a [MockWalkConfig] into:
///   • ordered route anchors (loop polygon / straight leg / waypoint polyline,
///     optionally auto-closed),
///   • a total route length and a distance→point interpolator ([cleanPointAt])
///     that [MockWalkRunner] paces in real time,
///   • deterministic fixed-speed plots ([plotPoints]/[generatePositions]) that
///     tests use to assert the anti-cheat invariants (bearing std-dev > 2°,
///     per-hop speed under the server cap, retained-point density).
///
/// Jitter uses a seeded [Random] when supplied, so a whole walk is reproducible.
/// Geometry uses a local equirectangular approximation — accurate to centimetres
/// over the sub-kilometre routes the simulator generates.
library;

import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'mock_walk_config.dart';

/// Metres per degree of latitude (WGS-84 mean). Longitude scales by cos(latitude).
const double _metersPerDegLat = 111320.0;

/// A waypoint route whose last tap lands within this distance of its first
/// waypoint is already closed — auto-close appends nothing.
const double _autoCloseSkipMeters = 10.0;

/// One plotted step along the route: position + the heading used to reach it.
class MockRoutePoint {
  final double lat;
  final double lng;
  final double headingDegrees;
  const MockRoutePoint(this.lat, this.lng, this.headingDegrees);
}

class MockWalkEngine {
  final MockWalkConfig config;
  final Random _random;

  List<LatLng>? _anchors;
  List<double>? _cumulativeMeters;

  /// Plotted route is computed once per engine and reused, so a one-shot fix
  /// ([generatePositions]/[MockLocationService.getCurrentPosition]) stays
  /// internally consistent (and reproducible when a seeded [Random] is supplied).
  List<MockRoutePoint>? _plotted;

  MockWalkEngine(this.config, {Random? random}) : _random = random ?? Random();

  // ──────────────────────────────────────────────────────────────────────────
  // Route anchors
  // ──────────────────────────────────────────────────────────────────────────

  /// Ordered vertices of the route, before densification. Always >= 2 points.
  List<LatLng> buildRouteAnchors() => _anchors ??= _computeAnchors();

  List<LatLng> _computeAnchors() {
    switch (config.routeType) {
      case MockRouteType.loop:
        return _closedPolygon(
          config.startPoint,
          config.loopRadiusMeters,
          MockWalkConstants.loopVertexCount,
        );
      case MockRouteType.straight:
        final end = _offsetByBearing(
          config.startPoint,
          config.straightBearingDegrees,
          config.straightLengthMeters,
        );
        return [config.startPoint, end];
      case MockRouteType.multiWaypoint:
        if (config.waypoints.length < 2) {
          // Degenerate config: fall back to a short straight leg so the run is valid.
          final end = _offsetByBearing(
            config.startPoint,
            MockWalkConstants.defaultStraightBearingDegrees,
            MockWalkConstants.defaultStraightLengthMeters,
          );
          return [config.startPoint, end];
        }
        final anchors = List.of(config.waypoints);
        // Close the loop back to the first tap so the walk can claim territory,
        // unless the tester already closed it (or opted out).
        if (config.autoCloseLoop &&
            _distance(anchors.last, anchors.first) > _autoCloseSkipMeters) {
          anchors.add(anchors.first);
        }
        return anchors;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Distance parameterisation (used by the live runner)
  // ──────────────────────────────────────────────────────────────────────────

  /// Cumulative distance to each anchor, `[0, …, totalLengthMeters]`.
  List<double> get _cumulative => _cumulativeMeters ??= _computeCumulative();

  List<double> _computeCumulative() {
    final anchors = buildRouteAnchors();
    final cumulative = <double>[0];
    for (var i = 1; i < anchors.length; i++) {
      cumulative.add(cumulative.last + _distance(anchors[i - 1], anchors[i]));
    }
    return cumulative;
  }

  /// Full route length along the anchor polyline, in metres.
  double get totalLengthMeters => _cumulative.last;

  /// The un-jittered point [meters] along the route (clamped to its ends).
  LatLng cleanPointAt(double meters) {
    final anchors = buildRouteAnchors();
    final cumulative = _cumulative;
    final clamped = meters.clamp(0.0, totalLengthMeters);
    for (var seg = 1; seg < anchors.length; seg++) {
      if (clamped > cumulative[seg] && seg < anchors.length - 1) continue;
      final segLength = cumulative[seg] - cumulative[seg - 1];
      if (segLength <= 0) continue;
      final frac = ((clamped - cumulative[seg - 1]) / segLength).clamp(0.0, 1.0);
      final from = anchors[seg - 1];
      final to = anchors[seg];
      return LatLng(
        from.latitude + (to.latitude - from.latitude) * frac,
        from.longitude + (to.longitude - from.longitude) * frac,
      );
    }
    return anchors.last;
  }

  /// Applies the configured Gaussian positional jitter to [point] (identity when
  /// jitter is disabled). Consumes the engine's seeded [Random].
  LatLng jitterPoint(LatLng point) {
    if (!config.jitterEnabled) return point;
    final north = _gaussian() * MockWalkConstants.jitterSigmaMeters;
    final east = _gaussian() * MockWalkConstants.jitterSigmaMeters;
    return _offsetMeters(point, north, east);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Fixed-speed plot (deterministic given the seeded Random — used by tests
  // and the one-shot fix; the live stream is paced by MockWalkRunner instead)
  // ──────────────────────────────────────────────────────────────────────────

  /// Walks the route at the configured (fixed) speed, emitting a jittered fix per
  /// [MockWalkConstants.tickInterval]. Pure geometry — no timing — so it is
  /// unit-testable. Memoized: computed once per engine.
  List<MockRoutePoint> plotPoints() => _plotted ??= _computePlot();

  List<MockRoutePoint> _computePlot() {
    final stepMeters = config.speedMps * MockWalkConstants.tickInterval.inMilliseconds / 1000.0;
    final points = <MockRoutePoint>[];

    final first = jitterPoint(cleanPointAt(0));
    points.add(MockRoutePoint(first.latitude, first.longitude, 0.0));

    for (var travelled = stepMeters; travelled < totalLengthMeters; travelled += stepMeters) {
      _addJitteredFix(points, cleanPointAt(travelled));
    }

    // Guarantee the final anchor is represented (last partial step may fall short).
    final last = jitterPoint(cleanPointAt(totalLengthMeters));
    final prev = points.last;
    if (_distance(LatLng(prev.lat, prev.lng), last) > 0.5) {
      _addJitteredFix(points, last, alreadyJittered: true);
    }

    return points;
  }

  void _addJitteredFix(List<MockRoutePoint> points, LatLng clean, {bool alreadyJittered = false}) {
    final fix = alreadyJittered ? clean : jitterPoint(clean);
    final prev = points.last;
    final heading = _bearing(prev.lat, prev.lng, fix.latitude, fix.longitude);
    points.add(MockRoutePoint(fix.latitude, fix.longitude, heading));
  }

  /// Maps plotted points to [Position]s with timestamps spaced by the tick interval,
  /// starting at [startTime]. Deterministic — used by tests to assert speed/bearing.
  List<Position> generatePositions({required DateTime startTime}) {
    final plotted = plotPoints();
    final tick = MockWalkConstants.tickInterval;
    return [
      for (var i = 0; i < plotted.length; i++)
        toPosition(plotted[i], startTime.add(tick * i), speedMps: config.speedMps),
    ];
  }

  /// Builds the geolocator [Position] the journey pipeline consumes for a fix.
  Position toPosition(MockRoutePoint p, DateTime timestamp, {required double speedMps}) {
    return Position(
      latitude: p.lat,
      longitude: p.lng,
      timestamp: timestamp,
      accuracy: MockWalkConstants.reportedAccuracyMeters,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: p.headingDegrees,
      headingAccuracy: 0,
      speed: speedMps,
      speedAccuracy: 0,
      isMocked: true,
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Geometry helpers
  // ──────────────────────────────────────────────────────────────────────────

  /// Standard normal sample via the Box–Muller transform.
  double _gaussian() {
    final u1 = _random.nextDouble().clamp(1e-9, 1.0);
    final u2 = _random.nextDouble();
    return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
  }

  static List<LatLng> _closedPolygon(LatLng centre, double radiusMeters, int vertices) {
    final pts = <LatLng>[];
    for (var i = 0; i < vertices; i++) {
      final angle = 2 * pi * i / vertices;
      pts.add(_offsetMeters(centre, radiusMeters * cos(angle), radiusMeters * sin(angle)));
    }
    pts.add(pts.first); // close the loop back to the first vertex
    return pts;
  }

  static LatLng _offsetByBearing(LatLng from, double bearingDegrees, double distanceMeters) {
    final rad = bearingDegrees * pi / 180.0;
    return _offsetMeters(from, distanceMeters * cos(rad), distanceMeters * sin(rad));
  }

  static LatLng _offsetMeters(LatLng from, double northMeters, double eastMeters) {
    final dLat = northMeters / _metersPerDegLat;
    final dLng = eastMeters / (_metersPerDegLat * cos(from.latitude * pi / 180.0));
    return LatLng(from.latitude + dLat, from.longitude + dLng);
  }

  static double _distance(LatLng a, LatLng b) =>
      Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);

  static double _bearing(double lat1, double lng1, double lat2, double lng2) {
    return Geolocator.bearingBetween(lat1, lng1, lat2, lng2);
  }
}
