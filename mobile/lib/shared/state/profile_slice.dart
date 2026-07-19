/// Profile state slice — hex count, streak, distance, rank.
/// Updated via SignalR UserStatsDelta push or full hydration on login.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:myloop/shared/services/territory_realtime_service.dart';

final _log = Logger('ProfileSlice');

class ProfileState {
  final int hexCount;
  final int totalHexesCaptured;
  final int totalHexesStolen;
  final int streak;
  final bool isStreakActive;
  final double distanceKm;
  final int rank;
  final bool isLoaded;

  const ProfileState({
    this.hexCount = 0,
    this.totalHexesCaptured = 0,
    this.totalHexesStolen = 0,
    this.streak = 0,
    this.isStreakActive = false,
    this.distanceKm = 0,
    this.rank = 0,
    this.isLoaded = false,
  });

  ProfileState copyWith({
    int? hexCount,
    int? totalHexesCaptured,
    int? totalHexesStolen,
    int? streak,
    bool? isStreakActive,
    double? distanceKm,
    int? rank,
    bool? isLoaded,
  }) {
    return ProfileState(
      hexCount: hexCount ?? this.hexCount,
      totalHexesCaptured: totalHexesCaptured ?? this.totalHexesCaptured,
      totalHexesStolen: totalHexesStolen ?? this.totalHexesStolen,
      streak: streak ?? this.streak,
      isStreakActive: isStreakActive ?? this.isStreakActive,
      distanceKm: distanceKm ?? this.distanceKm,
      rank: rank ?? this.rank,
      isLoaded: isLoaded ?? this.isLoaded,
    );
  }
}

class ProfileSlice extends Notifier<ProfileState> {
  @override
  ProfileState build() {
    // Listen to SignalR user stats pushes
    final realtime = ref.read(territoryRealtimeProvider);
    final sub = realtime.onUserStats.listen((delta) {
      _log.fine('Delta received: hexCount=${delta.hexCount}');
      state = state.copyWith(
        hexCount: delta.hexCount,
        totalHexesCaptured: delta.totalHexesCaptured,
        totalHexesStolen: delta.totalHexesStolen,
        streak: delta.streak,
        isStreakActive: delta.isStreakActive,
        distanceKm: delta.distanceKm,
      );
    });
    ref.onDispose(sub.cancel);
    return const ProfileState();
  }

  /// Full hydration from game-state endpoint (login / app resume).
  void hydrate(Map<String, dynamic> data) {
    applyStats(
      hexCount: data['hexCount'] as int? ?? 0,
      totalHexesCaptured: data['totalHexesCaptured'] as int? ?? 0,
      totalHexesStolen: data['totalHexesStolen'] as int? ?? 0,
      streak: data['streak'] as int? ?? 0,
      isStreakActive: data['isStreakActive'] as bool? ?? false,
      distanceKm: (data['distanceKm'] as num?)?.toDouble() ?? 0,
      rank: data['rank'] as int? ?? 0,
    );
  }

  /// Sets every stat field at once — the typed counterpart to [hydrate] for
  /// callers that already have parsed values (e.g. seeding from a freshly
  /// fetched `User`, or restoring from `ProfileCache` while offline) rather
  /// than a raw game-state JSON map.
  void applyStats({
    int hexCount = 0,
    int totalHexesCaptured = 0,
    int totalHexesStolen = 0,
    int streak = 0,
    bool isStreakActive = false,
    double distanceKm = 0,
    int rank = 0,
  }) {
    state = ProfileState(
      hexCount: hexCount,
      totalHexesCaptured: totalHexesCaptured,
      totalHexesStolen: totalHexesStolen,
      streak: streak,
      isStreakActive: isStreakActive,
      distanceKm: distanceKm,
      rank: rank,
      isLoaded: true,
    );
  }

  /// Update rank (from leaderboard fetch — not pushed via SignalR).
  void updateRank(int newRank) {
    state = state.copyWith(rank: newRank);
  }
}

final profileSliceProvider = NotifierProvider<ProfileSlice, ProfileState>(ProfileSlice.new);
