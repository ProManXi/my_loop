import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/profile_cache.dart';
import 'package:myloop/shared/services/user_state.dart';

/// Unit tests for [ProfileCache.encode] / [ProfileCache.decode] — the pure JSON
/// codec behind the offline-restored, user-bound profile. Both the firebaseUid
/// and the server userId are load-bearing: a decode that accepted a payload
/// missing either would restore a session that can't be safely bound to a user.
void main() {
  const uid = 'firebase-uid-123';

  CachedProfile sample() => const CachedProfile(
        firebaseUid: uid,
        profile: UserProfile(
          userId: 'user-abc',
          avatarId: 4,
          color: '#123456',
          displayName: 'Walker',
          hexCount: 12,
          streak: 5,
          distanceKm: 3.5,
          rank: 7,
        ),
      );

  group('encode/decode round trip', () {
    test('preserves every field', () {
      final decoded = ProfileCache.decode(ProfileCache.encode(sample()));

      expect(decoded, isNotNull);
      expect(decoded!.firebaseUid, uid);
      expect(decoded.profile.userId, 'user-abc');
      expect(decoded.profile.avatarId, 4);
      expect(decoded.profile.color, '#123456');
      expect(decoded.profile.displayName, 'Walker');
      expect(decoded.profile.hexCount, 12);
      expect(decoded.profile.streak, 5);
      expect(decoded.profile.distanceKm, 3.5);
      expect(decoded.profile.rank, 7);
    });
  });

  group('decode rejects unsafe payloads', () {
    test('returns null on malformed JSON', () {
      expect(ProfileCache.decode('not json at all'), isNull);
    });

    test('returns null when firebaseUid is missing', () {
      expect(ProfileCache.decode('{"userId":"user-abc"}'), isNull);
    });

    test('returns null when firebaseUid is empty', () {
      expect(ProfileCache.decode('{"firebaseUid":"","userId":"user-abc"}'), isNull);
    });

    test('returns null when server userId is missing', () {
      expect(ProfileCache.decode('{"firebaseUid":"$uid"}'), isNull);
    });
  });

  group('decode applies defaults for optional fields', () {
    test('missing stats fall back to safe defaults', () {
      final decoded =
          ProfileCache.decode('{"firebaseUid":"$uid","userId":"user-abc"}');

      expect(decoded, isNotNull);
      expect(decoded!.profile.avatarId, 0);
      expect(decoded.profile.color, '#00D4AA');
      expect(decoded.profile.displayName, 'Player');
      expect(decoded.profile.hexCount, 0);
      expect(decoded.profile.streak, 0);
      expect(decoded.profile.distanceKm, 0);
      expect(decoded.profile.rank, 0);
    });
  });
}
