/// User state provider — holds the current user's identity in memory.
///
/// Manages user id, avatar ID, color, and display name so that identity
/// changes immediately reflect across all screens. Game stats (hex count,
/// streak, distance, rank) are owned exclusively by `profileSliceProvider`
/// (see `shared/state/profile_slice.dart`) — see issue #113: this notifier
/// used to also mirror those stats from live SignalR pushes, which let it
/// drift from the slice under ties/scopes since two independent listeners
/// updated two independent copies of the same numbers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myloop/shared/services/api_service.dart';

/// Immutable snapshot of the current user's identity.
class UserProfile {
  final String? userId;
  final int avatarId;
  final String color;
  final String displayName;

  const UserProfile({
    this.userId,
    this.avatarId = 0,
    this.color = '#00D4AA',
    this.displayName = 'Player',
  });

  UserProfile copyWith({
    String? userId,
    int? avatarId,
    String? color,
    String? displayName,
  }) {
    return UserProfile(
      userId: userId ?? this.userId,
      avatarId: avatarId ?? this.avatarId,
      color: color ?? this.color,
      displayName: displayName ?? this.displayName,
    );
  }
}

/// Notifier that manages user identity state.
class UserProfileNotifier extends Notifier<UserProfile> {
  @override
  UserProfile build() => const UserProfile();

  /// Updates avatar and color together.
  void updateAvatarAndColor(int avatarId, String color) {
    state = state.copyWith(avatarId: avatarId, color: color);
    _persistUpdate(avatarId: avatarId, color: color);
  }

  /// Updates display name.
  void updateDisplayName(String name) {
    state = state.copyWith(displayName: name);
    _persistUpdate(displayName: name);
  }

  /// Fire-and-forget API call to persist profile changes.
  void _persistUpdate({String? displayName, int? avatarId, String? color}) {
    final userId = state.userId;
    if (userId == null) return;
    final api = ref.read(apiServiceProvider);
    api.updateUser(userId: userId, displayName: displayName, avatarId: avatarId, color: color);
  }

  /// Sets the full identity from API data.
  void setFromApi({
    required String userId,
    required int avatarId,
    required String color,
    required String displayName,
  }) {
    state = UserProfile(
      userId: userId,
      avatarId: avatarId,
      color: color,
      displayName: displayName,
    );
  }

  /// Resets profile to default (used on sign-out).
  void clear() {
    state = const UserProfile();
  }
}

/// Global user profile provider — watched by profile, home, and avatar widgets.
final userProfileProvider =
    NotifierProvider<UserProfileNotifier, UserProfile>(UserProfileNotifier.new);
