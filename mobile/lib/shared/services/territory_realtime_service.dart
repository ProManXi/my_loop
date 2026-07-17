/// Real-time territory update service using SignalR.
///
/// Connects to the backend TerritoryHub and receives:
/// - Public: hex ownership changes (region-scoped)
/// - Personal: user stats, XP, missions, achievements (user-group-scoped)
///
/// Connection lifecycle: connect once after login, stays alive until logout.
/// Authenticates personal events via a bearer-token factory that re-reads the current
/// Firebase ID token on every (re)connect, never a URL-embedded token (#102).
library;

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:signalr_netcore/signalr_client.dart';

import 'package:myloop/shared/services/api_service.dart';

final _log = Logger('SignalR');

/// Event emitted when hex ownership changes are received from the server.
class HexChangeEvent {
  final String h3Index;
  final double centerLat;
  final double centerLng;
  final String newOwnerId;
  final String newOwnerColor;
  final String newOwnerDisplayName;
  final String? previousOwnerId;

  HexChangeEvent({
    required this.h3Index,
    required this.centerLat,
    required this.centerLng,
    required this.newOwnerId,
    required this.newOwnerColor,
    required this.newOwnerDisplayName,
    this.previousOwnerId,
  });

  factory HexChangeEvent.fromJson(Map<String, dynamic> json) {
    return HexChangeEvent(
      h3Index: json['h3Index'] as String,
      centerLat: (json['centerLat'] as num).toDouble(),
      centerLng: (json['centerLng'] as num).toDouble(),
      newOwnerId: json['newOwnerId'] as String,
      newOwnerColor: json['newOwnerColor'] as String,
      newOwnerDisplayName: json['newOwnerDisplayName'] as String,
      previousOwnerId: json['previousOwnerId'] as String?,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Personal delta event classes
// ─────────────────────────────────────────────────────────────────────────────

class UserStatsDelta {
  final int hexCount;
  final int totalHexesCaptured;
  final int totalHexesStolen;
  final int streak;
  final bool isStreakActive;
  final double distanceKm;

  UserStatsDelta.fromJson(Map<String, dynamic> json)
      : hexCount = json['hexCount'] as int? ?? 0,
        totalHexesCaptured = json['totalHexesCaptured'] as int? ?? 0,
        totalHexesStolen = json['totalHexesStolen'] as int? ?? 0,
        streak = json['streak'] as int? ?? 0,
        isStreakActive = json['isStreakActive'] as bool? ?? false,
        distanceKm = (json['distanceKm'] as num?)?.toDouble() ?? 0;
}

class XpDelta {
  final int xpGained;
  final int totalXp;
  final int level;
  final bool leveledUp;
  final int progressXp;
  final int neededXp;
  final double progressPercent;

  XpDelta.fromJson(Map<String, dynamic> json)
      : xpGained = json['xpGained'] as int? ?? 0,
        totalXp = (json['totalXp'] as num?)?.toInt() ?? 0,
        level = json['level'] as int? ?? 1,
        leveledUp = json['leveledUp'] as bool? ?? false,
        progressXp = json['progressXp'] as int? ?? 0,
        neededXp = json['neededXp'] as int? ?? 100,
        progressPercent = (json['progressPercent'] as num?)?.toDouble() ?? 0;
}

class MissionDelta {
  final List<MissionUpdateEvent> updates;
  final bool allMissionsComplete;
  final int bonusXp;

  MissionDelta.fromJson(Map<String, dynamic> json)
      : updates = (json['updates'] as List? ?? [])
            .map((e) => MissionUpdateEvent.fromJson(e as Map<String, dynamic>))
            .toList(),
        allMissionsComplete = json['allMissionsComplete'] as bool? ?? false,
        bonusXp = json['bonusXp'] as int? ?? 0;
}

class MissionUpdateEvent {
  final String missionId;
  final String type;
  final int currentProgress;
  final int targetValue;
  final bool completed;
  final int xpAwarded;

  MissionUpdateEvent.fromJson(Map<String, dynamic> json)
      : missionId = json['missionId'] as String? ?? '',
        type = json['type'] as String? ?? '',
        currentProgress = json['currentProgress'] as int? ?? 0,
        targetValue = json['targetValue'] as int? ?? 1,
        completed = json['completed'] as bool? ?? false,
        xpAwarded = json['xpAwarded'] as int? ?? 0;
}

class AchievementDelta {
  final List<AchievementUnlockEvent> unlocks;

  AchievementDelta.fromJson(Map<String, dynamic> json)
      : unlocks = (json['unlocks'] as List? ?? [])
            .map((e) => AchievementUnlockEvent.fromJson(e as Map<String, dynamic>))
            .toList();
}

class AchievementUnlockEvent {
  final String id;
  final String name;
  final String icon;
  final int xpAwarded;

  AchievementUnlockEvent.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String? ?? '',
        name = json['name'] as String? ?? '',
        icon = json['icon'] as String? ?? '',
        xpAwarded = json['xpAwarded'] as int? ?? 0;
}

// ─────────────────────────────────────────────────────────────────────────────

/// Service that manages the SignalR connection to the territory hub.
///
/// Singleton lifecycle: connect once on login (or warm session-restore), disconnect
/// only on logout. No other screen may call [connect]/[disconnect] on this instance —
/// doing so used to tear down the authenticated connection every time the Journey
/// screen was closed, leaving the rest of the app deaf to realtime updates until it
/// was reopened (#102 / ML-ERR-005).
class TerritoryRealtimeService {
  final String _baseUrl;
  HubConnection? _hubConnection;

  /// Count of connection attempts that actually reached [HubConnection.start] (i.e.
  /// were not short-circuited by the already-connected guard). Exposed only so tests
  /// can prove a failed attempt doesn't permanently wedge future [connect] calls.
  @visibleForTesting
  int connectAttempts = 0;
  final _changeController = StreamController<List<HexChangeEvent>>.broadcast();
  final _userStatsController = StreamController<UserStatsDelta>.broadcast();
  final _xpController = StreamController<XpDelta>.broadcast();
  final _missionController = StreamController<MissionDelta>.broadcast();
  final _achievementController = StreamController<AchievementDelta>.broadcast();
  final Set<String> _subscribedRegions = {};
  bool _isConnected = false;
  String? _userId;

  TerritoryRealtimeService({required String baseUrl}) : _baseUrl = baseUrl;

  // ── Public streams ──
  Stream<List<HexChangeEvent>> get onHexChanges => _changeController.stream;
  Stream<UserStatsDelta> get onUserStats => _userStatsController.stream;
  Stream<XpDelta> get onXp => _xpController.stream;
  Stream<MissionDelta> get onMissions => _missionController.stream;
  Stream<AchievementDelta> get onAchievements => _achievementController.stream;

  bool get isConnected => _isConnected;

  /// Connect to the SignalR hub with optional authentication.
  /// [token] — non-empty when the caller wants authenticated personal events; only
  /// used as a signal to attach [HttpConnectionOptions.accessTokenFactory] below, not
  /// embedded in the URL (the URL is logged by proxies/servers — a bearer token in it
  /// is a leak — and a URL-embedded token goes stale across the ~1h Firebase expiry,
  /// silently breaking `withAutomaticReconnect`'s reconnect attempts). The factory
  /// re-reads the current Firebase ID token on every (re)connect instead.
  /// [userId] — App user ID for joining personal group.
  Future<void> connect({String? token, String? userId}) async {
    if (_hubConnection != null) return;

    _userId = userId;
    final hubUrl = '$_baseUrl/hubs/territory';
    final options = (token != null && token.isNotEmpty)
        ? HttpConnectionOptions(
            accessTokenFactory: () async =>
                await fb.FirebaseAuth.instance.currentUser?.getIdToken() ?? '',
          )
        : null;

    connectAttempts++;
    _hubConnection = HubConnectionBuilder()
        .withUrl(hubUrl, options: options)
        .withAutomaticReconnect()
        .build();

    // Public event
    _hubConnection!.on('HexOwnershipChanged', _handleHexChanges);

    // Personal events
    _hubConnection!.on('UserStatsDelta', _handleUserStats);
    _hubConnection!.on('XpDelta', _handleXp);
    _hubConnection!.on('MissionDelta', _handleMissions);
    _hubConnection!.on('AchievementUnlocked', _handleAchievements);

    _hubConnection!.onclose(({error}) {
      _isConnected = false;
      _log.warning('Connection closed: $error');
    });

    _hubConnection!.onreconnected(({connectionId}) {
      _isConnected = true;
      _log.info('Reconnected: $connectionId');
      _resubscribeAll();
    });

    try {
      await _hubConnection!.start();
      _isConnected = true;
      _log.info('Connected to $hubUrl');

      // Join personal group if authenticated
      if (userId != null && userId.isNotEmpty) {
        await _hubConnection!.invoke('JoinUserGroup', args: [userId]);
        _log.fine('Joined user group: user_$userId');
      }
    } catch (e) {
      _isConnected = false;
      // Null the handle so the NEXT connect() call is a fresh attempt instead of a
      // permanent no-op: pre-fix, a failed start() left `_hubConnection` set, and the
      // guard at the top of this method silently short-circuited every later retry —
      // one bad connection attempt (e.g. no network at login) wedged the service deaf
      // for the rest of the app session (#102 / ML-ERR-005).
      _hubConnection = null;
      _log.warning('Connection failed', e);
    }
  }

  /// Subscribe to a geographic region by its H3 res-3 parent cell ID.
  Future<void> joinRegion(String regionId) async {
    if (!_isConnected || _subscribedRegions.contains(regionId)) return;
    _subscribedRegions.add(regionId);
    await _hubConnection?.invoke('JoinRegion', args: [regionId]);
  }

  /// Unsubscribe from a region.
  Future<void> leaveRegion(String regionId) async {
    if (!_isConnected || !_subscribedRegions.contains(regionId)) return;
    _subscribedRegions.remove(regionId);
    await _hubConnection?.invoke('LeaveRegion', args: [regionId]);
  }

  /// Update subscriptions based on visible map bounds.
  Future<void> updateRegions(Set<String> visibleRegions) async {
    final toLeave = _subscribedRegions.difference(visibleRegions);
    final toJoin = visibleRegions.difference(_subscribedRegions);

    for (final region in toLeave) {
      await leaveRegion(region);
    }
    for (final region in toJoin) {
      await joinRegion(region);
    }
  }

  /// Disconnect and clean up.
  Future<void> disconnect() async {
    if (_userId != null && _isConnected) {
      try {
        await _hubConnection?.invoke('LeaveUserGroup', args: [_userId!]);
      } catch (_) {}
    }
    _subscribedRegions.clear();
    _isConnected = false;
    _userId = null;
    await _hubConnection?.stop();
    _hubConnection = null;
  }

  void dispose() {
    disconnect();
    _changeController.close();
    _userStatsController.close();
    _xpController.close();
    _missionController.close();
    _achievementController.close();
  }

  // ── Event handlers ──

  void _handleHexChanges(List<Object?>? arguments) {
    if (arguments == null || arguments.isEmpty) return;
    final rawList = arguments[0];
    if (rawList is! List) return;

    final events = rawList
        .whereType<Map<String, dynamic>>()
        .map(HexChangeEvent.fromJson)
        .toList();

    if (events.isNotEmpty) {
      _changeController.add(events);
    }
  }

  void _handleUserStats(List<Object?>? arguments) {
    if (arguments == null || arguments.isEmpty) return;
    final raw = arguments[0];
    if (raw is! Map<String, dynamic>) return;
    _userStatsController.add(UserStatsDelta.fromJson(raw));
    _log.fine('UserStatsDelta received: hexCount=${raw['hexCount']}');
  }

  void _handleXp(List<Object?>? arguments) {
    if (arguments == null || arguments.isEmpty) return;
    final raw = arguments[0];
    if (raw is! Map<String, dynamic>) return;
    _xpController.add(XpDelta.fromJson(raw));
    _log.fine('XpDelta received: +${raw['xpGained']} XP');
  }

  void _handleMissions(List<Object?>? arguments) {
    if (arguments == null || arguments.isEmpty) return;
    final raw = arguments[0];
    if (raw is! Map<String, dynamic>) return;
    _missionController.add(MissionDelta.fromJson(raw));
    _log.fine('MissionDelta received');
  }

  void _handleAchievements(List<Object?>? arguments) {
    if (arguments == null || arguments.isEmpty) return;
    final raw = arguments[0];
    if (raw is! Map<String, dynamic>) return;
    _achievementController.add(AchievementDelta.fromJson(raw));
    _log.fine('AchievementUnlocked received');
  }

  Future<void> _resubscribeAll() async {
    // Re-join personal group
    if (_userId != null && _userId!.isNotEmpty) {
      try {
        await _hubConnection?.invoke('JoinUserGroup', args: [_userId!]);
      } catch (_) {}
    }
    // Re-join region groups
    final regions = Set<String>.from(_subscribedRegions);
    _subscribedRegions.clear();
    for (final region in regions) {
      await joinRegion(region);
    }
  }
}

/// Riverpod provider for the territory real-time service (singleton lifecycle).
final territoryRealtimeProvider = Provider<TerritoryRealtimeService>((ref) {
  final service = TerritoryRealtimeService(baseUrl: apiBaseUrl);
  ref.onDispose(() => service.dispose());
  return service;
});
