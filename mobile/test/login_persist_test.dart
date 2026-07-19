/// Tests for the offline login-persistence path (issue #19).
///
/// Covers the two pure pieces the fix relies on:
///   1. [ProfileCache] encode/decode round-trips the profile faithfully so an
///      offline launch restores the same logged-in user.
///   2. [isServerUnreachable] classifies "server can't be reached" errors
///      (the trigger for the offline fallback) without mistaking real HTTP
///      error responses for connectivity loss.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/profile_cache.dart';
import 'package:myloop/shared/services/user_state.dart';

DioException _dioError(DioExceptionType type, {Object? error}) => DioException(
      requestOptions: RequestOptions(path: '/api/users/by-uid/abc'),
      type: type,
      error: error,
    );

void main() {
  group('ProfileCache codec', () {
    test('round-trips a full profile bound to its Firebase uid', () {
      const cached = CachedProfile(
        firebaseUid: 'fb-uid-abc',
        profile: UserProfile(
          userId: 'user-123',
          avatarId: 4,
          color: '#6C5CE7',
          displayName: 'Robin',
        ),
        hexCount: 87,
        streak: 5,
        distanceKm: 12.5,
        rank: 3,
      );

      final restored = ProfileCache.decode(ProfileCache.encode(cached));

      expect(restored, isNotNull);
      final r = restored!;
      expect(r.firebaseUid, 'fb-uid-abc');
      expect(r.profile.userId, 'user-123');
      expect(r.profile.avatarId, 4);
      expect(r.profile.color, '#6C5CE7');
      expect(r.profile.displayName, 'Robin');
      expect(r.hexCount, 87);
      expect(r.streak, 5);
      expect(r.distanceKm, 12.5);
      expect(r.rank, 3);
    });

    test('returns null when there is no user id to restore a session from', () {
      // A profile without a userId can't represent a logged-in user.
      const anonymous = CachedProfile(
        firebaseUid: 'fb-uid-abc',
        profile: UserProfile(displayName: 'Player'),
      );
      expect(ProfileCache.decode(ProfileCache.encode(anonymous)), isNull);
    });

    test('returns null when the Firebase uid binding is missing', () {
      // Without the uid we can't prove the cache belongs to the current user,
      // so it must never be restored (issue #19 cross-user identity guard).
      const noUid = CachedProfile(
        firebaseUid: '',
        profile: UserProfile(userId: 'user-123'),
      );
      expect(ProfileCache.decode(ProfileCache.encode(noUid)), isNull);

      // A legacy payload with no firebaseUid key at all is also rejected.
      const legacy = '{"userId":"user-123","displayName":"Robin"}';
      expect(ProfileCache.decode(legacy), isNull);
    });

    test('returns null on malformed payload instead of throwing', () {
      expect(ProfileCache.decode('not json'), isNull);
      expect(ProfileCache.decode('[]'), isNull);
    });
  });

  group('isServerUnreachable', () {
    test('true for connectivity failures and timeouts', () {
      expect(isServerUnreachable(_dioError(DioExceptionType.connectionError)), isTrue);
      expect(isServerUnreachable(_dioError(DioExceptionType.connectionTimeout)), isTrue);
      expect(isServerUnreachable(_dioError(DioExceptionType.sendTimeout)), isTrue);
      expect(isServerUnreachable(_dioError(DioExceptionType.receiveTimeout)), isTrue);
    });

    test('true for an unknown error wrapping a SocketException', () {
      final e = _dioError(DioExceptionType.unknown, error: SocketException('no route to host'));
      expect(isServerUnreachable(e), isTrue);
    });

    test('false for a real HTTP error response (server reachable)', () {
      // A 500 means the server answered — the user is online, so we must NOT
      // silently fall back to a stale cached profile.
      expect(isServerUnreachable(_dioError(DioExceptionType.badResponse)), isFalse);
    });

    test('false for non-Dio and non-socket unknown errors', () {
      expect(isServerUnreachable(_dioError(DioExceptionType.unknown)), isFalse);
      expect(isServerUnreachable(Exception('boom')), isFalse);
      expect(isServerUnreachable('oops'), isFalse);
    });
  });
}
