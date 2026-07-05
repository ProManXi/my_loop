import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/step_claim_queue.dart';
import 'package:myloop/shared/util/local_day.dart';

final _log = Logger('BatchDrain');

/// Drains the [StepClaimQueue] in batches and POSTs to the server's
/// `/api/claims/batch-step` endpoint.
///
/// - Timer-based: fires every [_drainIntervalSeconds] seconds.
/// - Threshold-based: fires immediately when queue reaches [_batchThreshold].
/// - Exponential backoff on failure: 1s → 2s → 4s → 8s → 16s → 30s max.
/// - After successful drain, resets backoff and removes ACKed points from queue.
/// - Emits [onBatchResult] stream for the journey controller to update UI.
class BatchDrainService {
  final StepClaimQueue _queue;
  final ApiService _api;
  final String _userId;

  static const _drainIntervalSeconds = 10;
  static const _batchThreshold = 5;
  static const _maxBatchSize = 50;
  static const _maxBackoffSeconds = 30;

  Timer? _drainTimer;
  bool _draining = false;
  int _backoffSeconds = 0;
  int _consecutiveFailures = 0;
  bool _disposed = false;

  /// Stream of batch results for UI updates.
  final _resultController = StreamController<BatchResult>.broadcast();
  Stream<BatchResult> get onBatchResult => _resultController.stream;

  /// Stream of user-facing rejection messages (e.g. anti-cheat speed violation)
  /// for batches the server permanently refused. The offending points are dropped.
  final _rejectionController = StreamController<String>.broadcast();
  Stream<String> get onRejection => _rejectionController.stream;

  /// Current queue size (for UI indicators).
  int get queueSize => _queue.length;

  /// Whether we're currently in backoff (network issues).
  bool get isInBackoff => _backoffSeconds > 0;

  BatchDrainService({
    required StepClaimQueue queue,
    required ApiService api,
    required String userId,
  })  : _queue = queue,
        _api = api,
        _userId = userId;

  /// Start the periodic drain timer.
  void start() {
    _drainTimer?.cancel();
    _drainTimer = Timer.periodic(
      const Duration(seconds: _drainIntervalSeconds),
      (_) => _tryDrain(),
    );
  }

  /// Stop draining (e.g., when walk ends or on dispose).
  void stop() {
    _drainTimer?.cancel();
    _drainTimer = null;
  }

  /// Called when a new point is enqueued — triggers immediate drain if threshold met.
  void notifyEnqueue() {
    if (_queue.length >= _batchThreshold && !_draining) {
      _tryDrain();
    }
  }

  /// Force an immediate drain (e.g., on STOP & CAPTURE before showing celebration).
  /// Returns true if drain succeeded (all points ACKed), false on failure.
  Future<bool> drainNow() async {
    return await _tryDrain();
  }

  /// Attempt to drain the queue. Returns true if successful.
  Future<bool> _tryDrain() async {
    if (_draining || _disposed) return false;
    if (_queue.isEmpty) return true;

    _draining = true;
    var peeked = const <QueuedStepPoint>[];
    try {
      final points = _queue.peek(_maxBatchSize);
      if (points.isEmpty) return true;

      // Drain one walk at a time so each Claim the server upserts maps to exactly one walk
      // (#56). Points are FIFO, so a walk's points are contiguous — take the leading run that
      // shares the first point's session id; the next run drains on the following cycle.
      final rawSessionId = points.first.walkSessionId;
      final batch =
          points.takeWhile((p) => p.walkSessionId == rawSessionId).toList();
      peeked = batch;

      // Legacy points written before #56 carry no session id — assign a fresh one so the
      // server treats them as a standalone walk rather than rejecting an empty id.
      final sessionId = rawSessionId.isEmpty ? const Uuid().v4() : rawSessionId;

      final response = await _api.claimBatchStep(
        userId: _userId,
        // Player's local day — drives streak AND today's missions server-side.
        localDate: localGameDay(),
        walkSessionId: sessionId,
        points: batch,
      );

      if (response != null) {
        // Remove all points that the server acknowledged
        final ackedIds = response.results
            .map((r) => r.clientId)
            .toSet();
        await _queue.removeProcessed(ackedIds);

        // Reset backoff on success
        _backoffSeconds = 0;
        _consecutiveFailures = 0;

        // Emit result for UI
        if (!_disposed) {
          _resultController.add(response);
        }
        return true;
      } else {
        _handleFailure();
        return false;
      }
    } on BatchRejectedException catch (e) {
      // Permanent rejection (anti-cheat / invalid batch): the server will never
      // accept these points, so retrying would jam the queue forever. Drop them,
      // surface the reason, and treat this as a successful (non-backoff) cycle.
      _log.warning('Batch permanently rejected: ${e.message}');
      if (peeked.isNotEmpty) {
        await _queue.removeProcessed(peeked.map((p) => p.clientId).toSet());
      }
      _backoffSeconds = 0;
      _consecutiveFailures = 0;
      if (!_disposed) _rejectionController.add(e.message);
      return false;
    } on DioException catch (e) {
      _log.warning('Network error: ${e.message}');
      _handleFailure();
      return false;
    } catch (e) {
      _log.severe('Unexpected error', e);
      _handleFailure();
      return false;
    } finally {
      _draining = false;
    }
  }

  void _handleFailure() {
    _consecutiveFailures++;
    _backoffSeconds = min(
      _maxBackoffSeconds,
      pow(2, _consecutiveFailures).toInt(),
    );

    // Schedule a retry after backoff period
    if (!_disposed) {
      Future.delayed(Duration(seconds: _backoffSeconds), () {
        if (!_disposed) _tryDrain();
      });
    }
  }

  void dispose() {
    _disposed = true;
    stop();
    _resultController.close();
    _rejectionController.close();
  }
}

/// Result of a batch submission — mirrors [BatchStepClaimResponse] from server.
class BatchResult {
  final List<BatchPointResult> results;
  final BatchStats stats;
  final BatchXp xp;
  final List<BatchMission> missions;
  final List<BatchAchievement> achievements;

  BatchResult({
    required this.results,
    required this.stats,
    required this.xp,
    required this.missions,
    required this.achievements,
  });

  factory BatchResult.fromJson(Map<String, dynamic> json) {
    return BatchResult(
      results: (json['results'] as List<dynamic>? ?? [])
          .map((r) => BatchPointResult.fromJson(r as Map<String, dynamic>))
          .toList(),
      stats: BatchStats.fromJson(json['stats'] as Map<String, dynamic>? ?? {}),
      xp: BatchXp.fromJson(json['xp'] as Map<String, dynamic>? ?? {}),
      missions: (json['missions'] as List<dynamic>? ?? [])
          .map((m) => BatchMission.fromJson(m as Map<String, dynamic>))
          .toList(),
      achievements: (json['achievements'] as List<dynamic>? ?? [])
          .map((a) => BatchAchievement.fromJson(a as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Count of actually claimed hexes in this batch.
  int get claimedCount => results.where((r) => r.claimed).length;

  /// All boundaries from claimed hexes.
  List<List<List<double>>> get claimedBoundaries => results
      .where((r) => r.claimed && r.boundary != null)
      .map((r) => r.boundary!)
      .toList();
}

class BatchPointResult {
  final String clientId;
  final bool claimed;
  final int? cellId;
  final List<List<double>>? boundary;
  final bool wasStolen;
  final String? previousOwnerName;
  final String? skipReason;

  BatchPointResult({
    required this.clientId,
    required this.claimed,
    this.cellId,
    this.boundary,
    required this.wasStolen,
    this.previousOwnerName,
    this.skipReason,
  });

  factory BatchPointResult.fromJson(Map<String, dynamic> json) {
    List<List<double>>? boundary;
    if (json['boundary'] != null) {
      boundary = (json['boundary'] as List<dynamic>)
          .map((p) => (p as List<dynamic>).map((v) => (v as num).toDouble()).toList())
          .toList();
    }
    return BatchPointResult(
      clientId: json['clientId'] as String? ?? '',
      claimed: json['claimed'] as bool? ?? false,
      cellId: json['cellId'] as int?,
      boundary: boundary,
      wasStolen: json['wasStolen'] as bool? ?? false,
      previousOwnerName: json['previousOwnerName'] as String?,
      skipReason: json['skipReason'] as String?,
    );
  }
}

class BatchStats {
  final int hexCount;
  final int totalHexesCaptured;
  final int totalHexesStolen;
  final int streak;
  final bool isStreakActive;
  final double distanceKm;

  BatchStats({
    required this.hexCount,
    required this.totalHexesCaptured,
    required this.totalHexesStolen,
    required this.streak,
    required this.isStreakActive,
    required this.distanceKm,
  });

  factory BatchStats.fromJson(Map<String, dynamic> json) {
    return BatchStats(
      hexCount: json['hexCount'] as int? ?? 0,
      totalHexesCaptured: json['totalHexesCaptured'] as int? ?? 0,
      totalHexesStolen: json['totalHexesStolen'] as int? ?? 0,
      streak: json['streak'] as int? ?? 0,
      isStreakActive: json['isStreakActive'] as bool? ?? false,
      distanceKm: (json['distanceKm'] as num? ?? 0).toDouble(),
    );
  }
}

class BatchXp {
  final int xpGained;
  final int totalXp;
  final int level;
  final bool leveledUp;
  final int progressXp;
  final int neededXp;
  final double progressPercent;

  BatchXp({
    required this.xpGained,
    required this.totalXp,
    required this.level,
    required this.leveledUp,
    required this.progressXp,
    required this.neededXp,
    required this.progressPercent,
  });

  factory BatchXp.fromJson(Map<String, dynamic> json) {
    return BatchXp(
      xpGained: json['xpGained'] as int? ?? 0,
      totalXp: json['totalXp'] as int? ?? 0,
      level: json['level'] as int? ?? 1,
      leveledUp: json['leveledUp'] as bool? ?? false,
      progressXp: json['progressXp'] as int? ?? 0,
      neededXp: json['neededXp'] as int? ?? 0,
      progressPercent: (json['progressPercent'] as num? ?? 0).toDouble(),
    );
  }
}

class BatchMission {
  final String missionId;
  final String type;
  final int currentProgress;
  final int targetValue;
  final bool completed;
  final int xpAwarded;

  BatchMission({
    required this.missionId,
    required this.type,
    required this.currentProgress,
    required this.targetValue,
    required this.completed,
    required this.xpAwarded,
  });

  factory BatchMission.fromJson(Map<String, dynamic> json) {
    return BatchMission(
      missionId: json['missionId'] as String? ?? '',
      type: json['type'] as String? ?? '',
      currentProgress: json['currentProgress'] as int? ?? 0,
      targetValue: json['targetValue'] as int? ?? 0,
      completed: json['completed'] as bool? ?? false,
      xpAwarded: json['xpAwarded'] as int? ?? 0,
    );
  }
}

class BatchAchievement {
  final String id;
  final String name;
  final String icon;
  final int xpAwarded;

  BatchAchievement({
    required this.id,
    required this.name,
    required this.icon,
    required this.xpAwarded,
  });

  factory BatchAchievement.fromJson(Map<String, dynamic> json) {
    return BatchAchievement(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      icon: json['icon'] as String? ?? '',
      xpAwarded: json['xpAwarded'] as int? ?? 0,
    );
  }
}
