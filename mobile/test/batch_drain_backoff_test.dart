/// Regression tests for issue #119 (audit ML-ERR-022): the drain backoff was
/// cosmetic. On failure, `_handleFailure` computed a backoff and scheduled a
/// delayed retry — but the 10 s periodic timer kept calling `_tryDrain`
/// regardless, so the effective retry cadence during an outage stayed 10 s
/// forever (plus stacking duplicate scheduled retries). The backoff window
/// must actually gate timer/threshold drains, while STOP & CAPTURE's
/// `drainNow()` — an explicit user action — bypasses it.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/batch_drain_service.dart';
import 'package:myloop/shared/services/step_claim_queue.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// A Dio that counts `post` calls and either fails with a transient network
/// error or ACKs every submitted point, switchable per test phase.
class _SwitchableDio with DioMixin implements Dio {
  _SwitchableDio() {
    options = BaseOptions();
  }

  int postCount = 0;
  bool failing = true;

  @override
  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    postCount++;
    if (failing) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.connectionError,
      );
    }
    final points = ((data as Map<String, dynamic>)['points'] as List)
        .cast<Map<String, dynamic>>();
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: {
        'results': [
          for (final p in points)
            {'clientId': p['clientId'], 'claimed': false, 'skipReason': 'owned'},
        ],
      } as T,
    );
  }
}

QueuedStepPoint _pt(String id) => QueuedStepPoint(
      clientId: id,
      lat: 12.34,
      lng: 56.78,
      capturedAt: DateTime.utc(2026, 7, 6, 10),
      walkSessionId: 'walk-1',
    );

void main() {
  late Directory tmp;
  late StepClaimQueue queue;
  late _SwitchableDio dio;
  late DateTime clock;
  late BatchDrainService drain;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('batch_drain_backoff_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    queue = StepClaimQueue();
    await queue.init();
    await queue.enqueue(_pt('a'));
    await queue.enqueue(_pt('b'));

    dio = _SwitchableDio();
    clock = DateTime(2026, 7, 6, 10);
    drain = BatchDrainService(
      queue: queue,
      api: ApiService(dio: dio),
      userId: 'user-1',
      now: () => clock,
    );
  });

  tearDown(() async {
    drain.dispose();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('timer drains inside the backoff window make no network attempt', () async {
    expect(await drain.drainTick(), isFalse); // transient failure → backoff opens
    expect(dio.postCount, 1);
    expect(drain.isInBackoff, isTrue);

    // Same instant + just before the first (2 s) backoff expires: gated.
    expect(await drain.drainTick(), isFalse);
    clock = clock.add(const Duration(seconds: 1));
    expect(await drain.drainTick(), isFalse);
    expect(dio.postCount, 1);
  });

  test('drains resume after the backoff window and succeed', () async {
    await drain.drainTick(); // failure #1 → 2 s backoff
    clock = clock.add(const Duration(seconds: 60));

    dio.failing = false;
    expect(await drain.drainTick(), isTrue);
    expect(dio.postCount, 2);
    expect(drain.isInBackoff, isFalse);
    expect(queue.isEmpty, isTrue); // ACKed points removed from the WAL

    // Durability: the on-disk WAL agrees with memory (flutter-disk-concurrency-test).
    final reopened = StepClaimQueue();
    await reopened.init();
    expect(reopened.getAll(), isEmpty);
  });

  test('drainNow (STOP & CAPTURE) bypasses the backoff gate', () async {
    await drain.drainTick(); // failure → backoff opens
    expect(dio.postCount, 1);

    dio.failing = false;
    expect(await drain.drainNow(), isTrue); // user action → attempt anyway
    expect(dio.postCount, 2);
  });

  test('consecutive failures grow the window up to the 30s cap', () async {
    for (var i = 0; i < 6; i++) {
      await drain.drainTick();
      clock = clock.add(const Duration(seconds: 31)); // always past the cap
    }
    // 6 attempts happened because every tick sat beyond the (≤30 s) window.
    expect(dio.postCount, 6);

    await drain.drainTick(); // 7th failure → window reopens
    clock = clock.add(const Duration(seconds: 29)); // still inside the 30 s cap
    await drain.drainTick();
    expect(dio.postCount, 7); // gated — cap respected, no attempt at 29 s
  });
}
