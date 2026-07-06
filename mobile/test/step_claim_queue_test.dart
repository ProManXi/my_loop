import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/step_claim_queue.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Returns a fixed temp directory for [getApplicationDocumentsPath] so the
/// queue's write-ahead log lands on a real, inspectable file during tests.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

QueuedStepPoint _pt(String id, {String session = 's1'}) => QueuedStepPoint(
      clientId: id,
      lat: 12.34,
      lng: 56.78,
      capturedAt: DateTime.utc(2026, 6, 15, 10),
      walkSessionId: session,
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('step_claim_queue_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('enqueue/peek/removeProcessed roundtrip survives a reopen', () async {
    final q = StepClaimQueue();
    await q.init();

    await q.enqueue(_pt('a'));
    await q.enqueue(_pt('b'));
    await q.enqueue(_pt('c'));

    expect(q.length, 3);
    expect(q.peek(2).map((p) => p.clientId), ['a', 'b']);

    await q.removeProcessed({'b'});
    expect(q.getAll().map((p) => p.clientId), ['a', 'c']);

    // The WAL on disk must agree with memory after a removal.
    final reopened = StepClaimQueue();
    await reopened.init();
    expect(reopened.getAll().map((p) => p.clientId), ['a', 'c']);
  });

  // #56: a point's walkSessionId is the key that folds a whole walk into one Claim. It
  // must round-trip through the on-disk WAL, or a drain after an app-kill mid-walk would
  // lose the correlation and re-fragment the walk.
  test('walkSessionId round-trips through the on-disk WAL', () async {
    final q = StepClaimQueue();
    await q.init();
    await q.enqueue(_pt('a', session: 'walk-1'));
    await q.enqueue(_pt('b', session: 'walk-2'));

    final reopened = StepClaimQueue();
    await reopened.init();
    expect(
      reopened.getAll().map((p) => p.walkSessionId),
      ['walk-1', 'walk-2'],
      reason: 'session ids read from disk must match what was written',
    );
  });

  // Forward-compat: a WAL line written by a pre-#56 build has no walkSessionId key.
  // It must load as empty (the drainer then assigns a fresh session id) rather than throw.
  test('QueuedStepPoint.fromJson tolerates a missing walkSessionId', () {
    final p = QueuedStepPoint.fromJson({
      'clientId': 'legacy',
      'lat': 1.0,
      'lng': 2.0,
      'capturedAt': DateTime.utc(2026, 6, 15, 10).toIso8601String(),
    });
    expect(p.walkSessionId, '');
  });

  test('clear empties both memory and the on-disk WAL', () async {
    final q = StepClaimQueue();
    await q.init();
    await q.enqueue(_pt('a'));
    await q.clear();

    expect(q.isEmpty, isTrue);

    final reopened = StepClaimQueue();
    await reopened.init();
    expect(reopened.isEmpty, isTrue);
  });

  // #13: the WAL path is process-wide, not per-user. On sign-out the persisted queue MUST
  // be wiped, or the next user's queue re-reads it on init() and the drainer POSTs the
  // previous user's un-synced GPS points under the new session — mis-attributing territory.
  // clearPersisted() is the static, no-live-instance-needed hook the sign-out flow calls.
  test('clearPersisted wipes the WAL so the next user starts empty', () async {
    // User A leaves points un-drained on disk, then their live instance goes away
    // (journey controller disposed) WITHOUT clearing — only the sign-out hook does.
    final userA = StepClaimQueue();
    await userA.init();
    await userA.enqueue(_pt('a1', session: 'A-walk'));
    await userA.enqueue(_pt('a2', session: 'A-walk'));

    // Sign-out hook.
    await StepClaimQueue.clearPersisted();

    // The WAL file itself is gone, and a fresh queue (user B) reads nothing from disk.
    expect(await File('${tmp.path}/step_claim_queue.jsonl').exists(), isFalse);
    final userB = StepClaimQueue();
    await userB.init();
    expect(userB.isEmpty, isTrue,
        reason: "user B must not inherit user A's queued GPS points");
  });

  // clearPersisted also removes a leftover atomic-write temp file, so a crash mid-rewrite
  // before sign-out can't leave A's data where a later reopen might observe it.
  test('clearPersisted removes a leftover .tmp file too', () async {
    final tmpWal = File('${tmp.path}/step_claim_queue.jsonl.tmp');
    await tmpWal.writeAsString('{"clientId":"stale"}\n', flush: true);

    await StepClaimQueue.clearPersisted();

    expect(await tmpWal.exists(), isFalse);
  });

  // Regression for the StepClaimQueue write-lock (PR #17): an [enqueue] append
  // must not interleave with a [removeProcessed]/[clear] rewrite. Pre-fix, the
  // rewrite snapshots the cache, the append lands on the file, then the
  // rewrite's atomic rename replaces the file with a snapshot that lacks the
  // just-appended point — so the disk WAL silently diverges from memory and a
  // queued GPS point is lost if the OS kills the app. The invariant guarded
  // here: after any awaited batch of operations, a freshly-reopened queue
  // (reading only disk) must match the live queue's in-memory view.
  test('racing enqueue against a rewrite never desyncs disk from memory',
      () async {
    for (var i = 0; i < 25; i++) {
      final q = StepClaimQueue();
      await q.init();
      await q.clear();
      await q.enqueue(_pt('seed'));

      // Fire a rewrite (removeProcessed) and two appends (enqueue) without
      // awaiting between them, so they race on the same file.
      await Future.wait<void>([
        q.removeProcessed({'seed'}),
        q.enqueue(_pt('x$i')),
        q.enqueue(_pt('y$i')),
      ]);

      final reopened = StepClaimQueue();
      await reopened.init();

      expect(
        reopened.getAll().map((p) => p.clientId).toSet(),
        q.getAll().map((p) => p.clientId).toSet(),
        reason: 'disk and memory diverged on iteration $i',
      );
      // Also pin the surviving set so a regression that drops all data (leaving
      // both disk and memory empty) can't satisfy the invariant above.
      expect(
        q.getAll().map((p) => p.clientId).toSet(),
        {'x$i', 'y$i'},
        reason: 'expected the two appends to survive the rewrite on iteration $i',
      );
    }
  });
}
