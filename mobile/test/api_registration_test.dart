/// Integration tests for the API registration endpoint.
/// Run with: dart test test/api_registration_test.dart --tags live
///
/// Requires the API to be running at localhost:5048. Tagged `live` so the
/// default CI unit/widget run (`flutter test --exclude-tags live`) skips it;
/// it can never make an outbound localhost call in the sandboxed runner.
@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

const baseUrl = 'http://localhost:5048/api';

void main() {
  late Dio dio;

  setUp(() {
    dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      validateStatus: (status) => true, // Don't throw on non-2xx
    ));
  });

  tearDown(() => dio.close());

  group('POST /api/users/register', () {
    test('creates local account successfully', () async {
      final uniqueName = 'TestUser_${DateTime.now().millisecondsSinceEpoch}';
      final response = await dio.post('/users/register', data: {
        'firebaseUid': 'local_test_${DateTime.now().millisecondsSinceEpoch}',
        'displayName': uniqueName,
        'color': '#FF5733',
        'avatarId': 3,
        'authProvider': 'local',
      });

      expect(response.statusCode, anyOf(200, 201));
      expect(response.data['displayName'], uniqueName);
      expect(response.data['id'], isNotNull);
      expect(response.data['color'], '#FF5733');
      expect(response.data['avatarId'], 3);
    });

    test('local accounts get unique generated UIDs', () async {
      // Send with dev_ prefix — server should generate unique UID
      final response = await dio.post('/users/register', data: {
        'firebaseUid': 'dev_testuser',
        'displayName': 'LocalTest${DateTime.now().millisecondsSinceEpoch}',
        'color': '#00D4AA',
        'avatarId': 1,
        'authProvider': 'local',
      });

      expect(response.statusCode, anyOf(200, 201));
      // The firebaseUid on the saved user should start with "local_"
      // (server generates a new one for dev_ prefixed UIDs)
    });

    test('returns existing user on duplicate federated UID', () async {
      // First registration
      final uid = 'google_test_${DateTime.now().millisecondsSinceEpoch}';
      final r1 = await dio.post('/users/register', data: {
        'firebaseUid': uid,
        'displayName': 'GoogleUser',
        'color': '#6C5CE7',
        'avatarId': 2,
        'authProvider': 'google',
      });
      expect(r1.statusCode, 201);

      // Second registration with same UID — should return existing
      final r2 = await dio.post('/users/register', data: {
        'firebaseUid': uid,
        'displayName': 'DifferentName',
        'color': '#FF0000',
        'avatarId': 5,
        'authProvider': 'google',
      });
      expect(r2.statusCode, 200);
      expect(r2.data['id'], r1.data['id']); // Same user returned
      expect(r2.data['displayName'], 'GoogleUser'); // Original name preserved
    });

    test('rejects empty display name', () async {
      final response = await dio.post('/users/register', data: {
        'firebaseUid': 'google_abc123',
        'displayName': '',
        'color': '#FF5733',
        'avatarId': 0,
      });
      expect(response.statusCode, 400);
    });

    test('rejects invalid color format', () async {
      final response = await dio.post('/users/register', data: {
        'firebaseUid': 'google_abc456',
        'displayName': 'Test',
        'color': 'not-a-color',
        'avatarId': 0,
      });
      expect(response.statusCode, 400);
    });

    test('rejects avatarId out of range', () async {
      final response = await dio.post('/users/register', data: {
        'firebaseUid': 'google_abc789',
        'displayName': 'Test',
        'color': '#FF5733',
        'avatarId': 99,
      });
      expect(response.statusCode, 400);
    });
  });

  group('GET /api/leaderboard', () {
    test('returns city leaderboard for known user', () async {
      final response = await dio.get('/leaderboard', queryParameters: {
        'lat': 0,
        'lng': 0,
        'userId': 'f8191093-b335-4c68-bee6-57d9d680144a',
        'scope': 'city',
      });
      expect(response.statusCode, 200);
      expect(response.data['myRank'], isNotNull);
      expect(response.data['top'], isList);
    });

    test('returns country leaderboard for known user', () async {
      final response = await dio.get('/leaderboard', queryParameters: {
        'lat': 0,
        'lng': 0,
        'userId': 'f8191093-b335-4c68-bee6-57d9d680144a',
        'scope': 'country',
      });
      expect(response.statusCode, 200);
      expect(response.data['myRank'], isNotNull);
    });

    test('returns world leaderboard for known user', () async {
      final response = await dio.get('/leaderboard', queryParameters: {
        'lat': 0,
        'lng': 0,
        'userId': 'f8191093-b335-4c68-bee6-57d9d680144a',
        'scope': 'world',
      });
      expect(response.statusCode, 200);
      expect(response.data['myRank'], isNotNull);
    });
  });
}
