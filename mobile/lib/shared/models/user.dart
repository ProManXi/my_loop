/// User model for the MyLoop application.
///
/// Represents a registered player in the system. Maps directly to the
/// `User` entity returned by the .NET backend API.
/// Fields include identity (Firebase UID), display preferences (name, color,
/// avatar), and are serializable to/from JSON for API communication.
library;

/// The application user model, mirroring the backend `User` entity.
///
/// Used throughout the app to represent the currently signed-in player
/// and other players visible on the leaderboard or territory map.
class AppUser {
  final String id;
  final String displayName;
  final String color; // hex color like #FF5733
  final int avatarId;
  final int hexCount;
  final int totalHexesCaptured;
  final int streak;
  final double distanceKm;

  const AppUser({
    required this.id,
    required this.displayName,
    required this.color,
    required this.avatarId,
    this.hexCount = 0,
    this.totalHexesCaptured = 0,
    this.streak = 0,
    this.distanceKm = 0,
  });

  /// Deserializes a user from a JSON map returned by the API.
  ///
  /// The server no longer returns `firebaseUid` or home coordinates in user payloads
  /// (#100): the caller already knows its own Firebase UID from the auth session, and
  /// other users' home locations are PII that is never exposed.
  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      color: json['color'] as String,
      avatarId: (json['avatarId'] as num).toInt(),
      hexCount: (json['hexCount'] as num?)?.toInt() ?? 0,
      totalHexesCaptured: (json['totalHexesCaptured'] as num?)?.toInt() ?? 0,
      streak: (json['streak'] as num?)?.toInt() ?? 0,
      distanceKm: (json['distanceKm'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Serializes this user to a JSON map for API requests.
  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'color': color,
    'avatarId': avatarId,
    'hexCount': hexCount,
    'streak': streak,
    'distanceKm': distanceKm,
  };
}
