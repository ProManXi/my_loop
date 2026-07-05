import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/shared/util/local_day.dart';

void main() {
  group('localGameDay', () {
    test('formats as zero-padded yyyy-MM-dd', () {
      expect(localGameDay(DateTime(2026, 3, 5)), '2026-03-05');
      expect(localGameDay(DateTime(2026, 12, 25)), '2026-12-25');
    });

    test('uses the local calendar date (not UTC) of the given clock', () {
      // A local wall-clock time near midnight must format to the LOCAL date, so a player's
      // "today" is their own, not the server's UTC day.
      final localNearMidnight = DateTime(2026, 1, 1, 23, 30);
      expect(localGameDay(localNearMidnight), '2026-01-01');
    });
  });
}
