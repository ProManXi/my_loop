/// Leaderboard entry model for the MyLoop ranking system.
///
/// Represents one row in the leaderboard, containing a player's rank,
/// territory stats, and display info (avatar, color, name).
/// Returned by the `/api/leaderboard` endpoint.
library;

/// A single entry in the local or global leaderboard.
///
/// The leaderboard is a periodic SNAPSHOT (rebuilt by the backend's
/// `RefreshLeaderboard`), so every field here is a snapshot value taken at that
/// moment: [cellCount] / [areaM2] / [rank]. It deliberately does NOT carry the
/// player's live `User.HexCount`: mixing a live counter with the snapshot count
/// and rank made a row's tier badge disagree with its shown count between
/// refreshes (see bug-2026-07-02-leaderboard-tier-uses-live-hexcount-vs-snapshot-cellcount).
/// The backend still sends `userHexCount`/`userStreak`/`userDistanceKm`; they are
/// intentionally ignored so no display can source a hex quantity other than [cellCount].
class LeaderboardEntry {
  final String userId;
  final String displayName;
  final int avatarId;
  final String color;
  final int cellCount;
  final double areaM2;
  final int rank;

  const LeaderboardEntry({
    required this.userId,
    required this.displayName,
    required this.avatarId,
    required this.color,
    required this.cellCount,
    required this.areaM2,
    required this.rank,
  });

  /// Deserializes a leaderboard entry from a JSON map returned by the API.
  factory LeaderboardEntry.fromJson(Map<String, dynamic> json) {
    return LeaderboardEntry(
      userId: json['userId'] as String,
      displayName: json['userName'] as String,
      avatarId: (json['userAvatar'] as num).toInt(),
      color: json['userColor'] as String,
      cellCount: (json['cellCount'] as num).toInt(),
      areaM2: (json['areaM2'] as num).toDouble(),
      rank: (json['rank'] as num).toInt(),
    );
  }
}

/// Complete leaderboard API response including the user's personal rank.
class LeaderboardResponse {
  final List<LeaderboardEntry> top;
  final int? myRank;

  const LeaderboardResponse({required this.top, this.myRank});

  factory LeaderboardResponse.fromJson(Map<String, dynamic> json) {
    final list = json['top'] as List;
    final myRankData = json['myRank'] as Map<String, dynamic>?;
    return LeaderboardResponse(
      top: list.map((j) => LeaderboardEntry.fromJson(j as Map<String, dynamic>)).toList(),
      myRank: (myRankData?['rank'] as num?)?.toInt(),
    );
  }
}
