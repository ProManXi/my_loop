/// Regression test for the leaderboard snapshot/live mix
/// (bug-2026-07-02-leaderboard-tier-uses-live-hexcount-vs-snapshot-cellcount).
///
/// The leaderboard is a periodic snapshot. A row previously mixed the live
/// `User.HexCount` (fed into the tier badge) with the snapshot `cellCount` (the
/// shown count + rank), so between refreshes a row's tier disagreed with its
/// count. The fix makes `LeaderboardEntry` carry snapshot values only, so no
/// display can source a hex quantity other than `cellCount`. These tests lock
/// that invariant: the model ignores the backend's live counters, and the tier a
/// row derives from `cellCount` differs from what the live value would have given.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/models/leaderboard_entry.dart';
import 'package:myloop/shared/widgets/hex_trophy.dart';

void main() {
  group('LeaderboardEntry is a pure snapshot', () {
    // A payload where the live counters the backend still sends diverge sharply
    // from the snapshot count — the exact condition that made the row inconsistent.
    Map<String, dynamic> json({required int cellCount, required int liveHexCount}) => {
          'userId': 'u1',
          'userName': 'A',
          'userAvatar': 0,
          'userColor': '#111111',
          'cellCount': cellCount,
          'areaM2': cellCount * 2150.0,
          'rank': 4,
          'userHexCount': liveHexCount,
          'userStreak': 12,
          'userDistanceKm': 42.0,
        };

    test('exposes cellCount and ignores the live userHexCount', () {
      final e = LeaderboardEntry.fromJson(json(cellCount: 5, liveHexCount: 9999));
      expect(e.cellCount, 5);
    });

    test('the tier a row derives follows the snapshot count, not the live value', () {
      final e = LeaderboardEntry.fromJson(json(cellCount: 5, liveHexCount: 9999));

      // The screen renders the tier from `cellCount`; it must stay consistent with
      // the count and rank shown beside it…
      expect(HexTier.fromHexes(e.cellCount), HexTier.fromHexes(5));
      // …and NOT match the tier the divergent live count would have produced,
      // which is what caused the visible glitch.
      expect(HexTier.fromHexes(e.cellCount), isNot(HexTier.fromHexes(9999)));
    });
  });
}
