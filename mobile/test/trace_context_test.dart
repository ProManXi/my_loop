import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/services/trace_context.dart';

/// Unit tests for [TraceContext] — the W3C `traceparent` generator that ties a
/// mobile action to its server logs and crash reports. A malformed header would
/// silently break that correlation, so the format and the `lastTraceId` bookkeeping
/// are pinned here.
void main() {
  // 00-<32 hex trace id>-<16 hex span id>-01
  final traceparentPattern = RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-01$');

  group('TraceContext.newTraceparent', () {
    test('produces a well-formed sampled W3C traceparent', () {
      expect(TraceContext.newTraceparent(), matches(traceparentPattern));
    });

    test('records the generated trace id as lastTraceId', () {
      final header = TraceContext.newTraceparent();
      final traceId = header.split('-')[1];
      expect(TraceContext.lastTraceId, traceId);
      expect(traceId.length, 32);
    });

    test('generates a unique trace id per call', () {
      final ids = List.generate(100, (_) => TraceContext.newTraceparent().split('-')[1]);
      expect(ids.toSet().length, 100, reason: 'trace ids must not collide');
    });

    test('generates a unique span id per call', () {
      final spans = List.generate(100, (_) => TraceContext.newTraceparent().split('-')[2]);
      expect(spans.toSet().length, 100, reason: 'span ids must not collide');
    });
  });
}
