/// The player's "game day": the device's current LOCAL calendar date formatted as
/// `yyyy-MM-dd`. Sent to the backend so daily missions and streaks roll over on the
/// player's local midnight rather than server UTC (the backend clamps it to UTC ±1).
///
/// [clock] is injectable so tests can pin the date.
library;

String localGameDay([DateTime? clock]) {
  final now = clock ?? DateTime.now();
  final month = now.month.toString().padLeft(2, '0');
  final day = now.day.toString().padLeft(2, '0');
  return '${now.year}-$month-$day';
}
