import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final _log = Logger('StepClaimQueue');

/// A persistent write-ahead log for GPS step claims.
///
/// Points are immediately written to disk (JSON lines format) so they survive
/// app kills, crashes, and network outages. The [BatchDrainService] reads
/// from this queue and POSTs batches to the server.
///
/// Thread-safety: all writes are serialized via [_writeLock].
class StepClaimQueue {
  /// Pre-#110 filename, shared across every account on the device. A queue
  /// keyed by this name survives sign-out, so the next account's drain could
  /// submit the previous account's leftover GPS points as its own territory
  /// claims. Deleted (never migrated — see [init]) the first time any account
  /// initializes a queue on an app build that has this fix.
  static const _legacyFileName = 'step_claim_queue.jsonl';

  File? _file;
  List<QueuedStepPoint>? _cache;

  /// Serializes every disk-mutating operation. Without this an [enqueue] append
  /// can interleave with a [removeProcessed]/[clear] rewrite: the rewrite snapshots
  /// the cache, the append lands on the file, then the rewrite's atomic rename
  /// replaces the file with a snapshot that lacks the just-appended point — so a
  /// queued GPS point survives only in memory and is lost if the OS kills the app.
  Future<void> _writeLock = Future<void>.value();

  /// Runs [action] after all previously-queued mutations complete, chaining the
  /// lock so callers are serialized regardless of how their futures interleave.
  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _writeLock;
    _writeLock = completer.future.then((_) {}, onError: (_) {});
    previous.whenComplete(() async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Initialize the queue for [userId] (resolves app documents directory).
  ///
  /// The WAL file is keyed by [userId] so one account's queue can never be
  /// drained under a different account's session (#110) — even if a caller
  /// forgets to [clear] on sign-out, the next account's [init] opens a
  /// distinct, empty file rather than inheriting this one's contents.
  Future<void> init(String userId) async {
    final dir = await getApplicationDocumentsDirectory();
    await _deleteLegacyFile(dir);
    _file = File('${dir.path}/step_claim_queue_${_sanitize(userId)}.jsonl');
    if (!await _file!.exists()) {
      await _file!.create(recursive: true);
    }
    _cache = await _readAll();
  }

  /// One-time migration off the pre-#110 shared filename: deleted rather than
  /// attributed to whichever account happens to init next, since that account
  /// may not be the one that wrote it.
  Future<void> _deleteLegacyFile(Directory dir) async {
    final legacy = File('${dir.path}/$_legacyFileName');
    if (await legacy.exists()) {
      try {
        await legacy.delete();
      } catch (e) {
        _log.warning('Failed to delete legacy step-claim queue file', e);
      }
    }
  }

  /// Keeps the on-disk filename limited to characters that are safe across
  /// filesystems, in case a userId ever contains a path separator or similar.
  static String _sanitize(String userId) =>
      userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// Enqueue a GPS point for later batch submission.
  Future<void> enqueue(QueuedStepPoint point) => _synchronized(() async {
        assert(_file != null, 'Call init() first');
        final line = jsonEncode(point.toJson());
        await _file!.writeAsString('$line\n', mode: FileMode.append, flush: true);
        _cache?.add(point);
      });

  /// Peek the first [count] items without removing them.
  List<QueuedStepPoint> peek(int count) {
    if (_cache == null) return [];
    return _cache!.take(count).toList();
  }

  /// Number of points currently queued.
  int get length => _cache?.length ?? 0;

  /// Whether queue is empty.
  bool get isEmpty => length == 0;

  /// Get all queued points.
  List<QueuedStepPoint> getAll() => List.unmodifiable(_cache ?? []);

  /// Remove processed points by their clientIds (called after server ACK).
  Future<void> removeProcessed(Set<String> clientIds) => _synchronized(() async {
        if (_cache == null || clientIds.isEmpty) return;
        _cache!.removeWhere((p) => clientIds.contains(p.clientId));
        await _rewriteFile();
      });

  /// Clear all entries (e.g., on logout).
  Future<void> clear() => _synchronized(() async {
        _cache?.clear();
        await _atomicWrite('');
      });

  /// Read all entries from disk (used on init and after crash recovery).
  Future<List<QueuedStepPoint>> _readAll() async {
    if (_file == null || !await _file!.exists()) return [];
    final contents = await _file!.readAsString();
    if (contents.trim().isEmpty) return [];

    final lines = contents.trim().split('\n');
    final points = <QueuedStepPoint>[];
    for (final line in lines) {
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        points.add(QueuedStepPoint.fromJson(json));
      } catch (e) {
        _log.warning('Skipping corrupt line', e);
      }
    }
    return points;
  }

  /// Rewrite entire file from cache (after removals).
  Future<void> _rewriteFile() async {
    final sb = StringBuffer();
    for (final point in _cache ?? <QueuedStepPoint>[]) {
      sb.writeln(jsonEncode(point.toJson()));
    }
    await _atomicWrite(sb.toString());
  }

  /// Crash-safe full-file write (CRITICAL-8): write to a sibling temp file,
  /// flush it, then atomically rename it over the target. A crash/power-loss
  /// mid-write can only leave the (ignored) temp file behind — the real WAL is
  /// never observed in a half-written/truncated state, so queued GPS points
  /// can't be silently lost by an interrupted rewrite.
  Future<void> _atomicWrite(String contents) async {
    if (_file == null) return;
    final tmp = File('${_file!.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(_file!.path);
  }
}

/// A single GPS point queued for batch submission.
class QueuedStepPoint {
  final String clientId;
  final double lat;
  final double lng;
  final DateTime capturedAt;

  /// Id of the walk this point belongs to. Persisted per point so a drain after an
  /// app-kill mid-walk still attributes points to their originating walk, and the server
  /// folds the whole walk into one Claim (one walk = one history entry, #56). Empty for
  /// points written by an older app build; the drainer assigns a fresh id to those.
  final String walkSessionId;

  QueuedStepPoint({
    required this.clientId,
    required this.lat,
    required this.lng,
    required this.capturedAt,
    required this.walkSessionId,
  });

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'lat': lat,
        'lng': lng,
        'capturedAt': capturedAt.toUtc().toIso8601String(),
        'walkSessionId': walkSessionId,
      };

  factory QueuedStepPoint.fromJson(Map<String, dynamic> json) {
    return QueuedStepPoint(
      clientId: json['clientId'] as String,
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      capturedAt: DateTime.parse(json['capturedAt'] as String),
      walkSessionId: json['walkSessionId'] as String? ?? '',
    );
  }
}
