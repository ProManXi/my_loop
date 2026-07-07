/// Unit tests for the [MockWalkConfig] / [SavedMockRoute] persistence codec (#160).
///
/// The codec is the trust boundary between the saved-route file and the
/// simulator: it must be tolerant (malformed → null, never a throw), re-clamp
/// numbers to the current bounds, and NEVER restore `enabled` — a persisted
/// blob must not be able to turn the simulator on by itself.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:myloop/shared/services/mock/mock_walk_config.dart';

void main() {
  const full = MockWalkConfig(
    enabled: true,
    routeType: MockRouteType.multiWaypoint,
    startPoint: LatLng(37.1, -122.2),
    waypoints: [LatLng(37.1, -122.2), LatLng(37.2, -122.3)],
    speedMps: 2.5,
    jitterEnabled: false,
    loopRadiusMeters: 60,
    straightLengthMeters: 300,
    straightBearingDegrees: 45,
    autoCloseLoop: false,
  );

  group('round trip', () {
    final decoded = MockWalkConfig.fromJson(full.toJson());

    test('preserves every field except enabled', () {
      expect(decoded, isNotNull);
      expect(decoded!.routeType, MockRouteType.multiWaypoint);
      expect(decoded.startPoint, const LatLng(37.1, -122.2));
      expect(decoded.waypoints, const [LatLng(37.1, -122.2), LatLng(37.2, -122.3)]);
      expect(decoded.speedMps, 2.5);
      expect(decoded.jitterEnabled, isFalse);
      expect(decoded.loopRadiusMeters, 60);
      expect(decoded.straightLengthMeters, 300);
      expect(decoded.straightBearingDegrees, 45);
      expect(decoded.autoCloseLoop, isFalse);
    });

    test('never restores enabled from disk', () {
      expect(full.enabled, isTrue);
      expect(decoded!.enabled, isFalse);
    });
  });

  group('tolerance', () {
    test('non-map input → null', () {
      expect(MockWalkConfig.fromJson(null), isNull);
      expect(MockWalkConfig.fromJson('a string'), isNull);
      expect(MockWalkConfig.fromJson([1, 2]), isNull);
    });

    test('missing or malformed startPoint → null', () {
      expect(MockWalkConfig.fromJson({'routeType': 'loop'}), isNull);
      expect(MockWalkConfig.fromJson({'startPoint': [1]}), isNull);
      expect(MockWalkConfig.fromJson({'startPoint': ['a', 'b']}), isNull);
    });

    test('out-of-range latitude → null', () {
      expect(MockWalkConfig.fromJson({'startPoint': [95.0, 0.0]}), isNull);
    });

    test('a corrupt waypoint corrupts the route (null, not a partial route)', () {
      final json = full.toJson()..['waypoints'] = [
        [37.1, -122.2],
        ['bad', 'point'],
      ];
      expect(MockWalkConfig.fromJson(json), isNull);
    });

    test('unknown routeType falls back to loop', () {
      final json = full.toJson()..['routeType'] = 'teleport';
      expect(MockWalkConfig.fromJson(json)!.routeType, MockRouteType.loop);
    });

    test('out-of-bounds numerics are re-clamped through copyWith', () {
      final json = full.toJson()
        ..['speedMps'] = 99.0
        ..['loopRadiusMeters'] = 1.0;
      final decoded = MockWalkConfig.fromJson(json)!;
      expect(decoded.speedMps, MockWalkConstants.maxSpeedMps);
      expect(decoded.loopRadiusMeters, MockWalkConstants.minLoopRadiusMeters);
    });

    test('non-finite numerics fall back to defaults', () {
      final json = full.toJson()..['speedMps'] = double.nan;
      expect(MockWalkConfig.fromJson(json)!.speedMps, MockWalkConstants.defaultSpeedMps);
    });
  });

  group('SavedMockRoute', () {
    final route = SavedMockRoute(name: 'Office loop', savedAt: DateTime(2026, 7, 1), config: full);

    test('round trips name, savedAt and config', () {
      final decoded = SavedMockRoute.fromJson(route.toJson());
      expect(decoded, isNotNull);
      expect(decoded!.name, 'Office loop');
      expect(decoded.savedAt, DateTime(2026, 7, 1));
      expect(decoded.config.routeType, MockRouteType.multiWaypoint);
    });

    test('blank name → null', () {
      expect(SavedMockRoute.fromJson(route.toJson()..['name'] = '  '), isNull);
    });

    test('corrupt embedded config → null', () {
      expect(SavedMockRoute.fromJson(route.toJson()..['config'] = 'junk'), isNull);
    });

    test('unparseable savedAt is tolerated (route still loads)', () {
      final decoded = SavedMockRoute.fromJson(route.toJson()..['savedAt'] = 'yesterday-ish');
      expect(decoded, isNotNull);
      expect(decoded!.name, 'Office loop');
    });
  });
}
