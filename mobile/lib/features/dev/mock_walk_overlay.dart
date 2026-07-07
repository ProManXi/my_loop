/// MyLoop — Mock Walk Simulation: on-screen debug panel (#29, reworked in #160)
///
/// Compact panel shown only while a debug mock walk is running, styled with the
/// app design system. While the walk runs it is a live HUD (distance, %,
/// elapsed/ETA, speed, retained/raw fixes) WITH run controls — pause/resume and
/// live speed nudges that forward to the running [MockWalkRunner] through
/// [mockWalkRunProvider]; once the synthetic stream ends it becomes a
/// counts-only result summary so a desk tester sees the outcome without logs.
///
/// The telemetry it shows never feeds back into the GPS stream; the controls
/// change pacing only through the runner's clamped, anti-cheat-safe methods.
/// Callers gate it behind `kDebugMode` so it never ships in a release build.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:myloop/app/theme.dart';
import 'package:myloop/features/journey/journey_controller.dart';
import 'package:myloop/shared/services/mock/mock_walk_run_state.dart';

/// User-facing copy for the panel (CLAUDE.md: no hardcoded strings inline).
class _Strings {
  _Strings._();
  static const liveTitle = 'MOCK WALK';
  static const resultTitle = 'MOCK RESULT';
  static const pausedBadge = 'PAUSED';
  static const distanceLabel = 'Dist';
  static const doneLabel = 'Done';
  static const timeLabel = 'Time';
  static const speedLabel = 'Speed';
  static const pointsLabel = 'Pts';
  static const claimedLabel = 'Claimed';
  static const rejectedLabel = 'Rejected';
  static const statusOk = 'STATUS: OK';
  static const statusCheck = 'STATUS: CHECK';
  static const pauseTooltip = 'Pause walk';
  static const resumeTooltip = 'Resume walk';
  static const slowerTooltip = 'Slower';
  static const fasterTooltip = 'Faster';
}

/// Step applied per speed-nudge tap, m/s. The runner clamps the result to the
/// simulator bounds, so mashing the button can never exceed the anti-cheat cap.
const double _speedStepMps = 0.5;

class MockWalkOverlay extends ConsumerWidget {
  const MockWalkOverlay({super.key});

  static String _clock(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(mockWalkRunProvider);
    final journey = ref.watch(journeyControllerProvider);
    if (!run.isActive) return const SizedBox.shrink();

    final retained = journey.path.length;

    return Card(
      child: Container(
        width: 208,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(run),
            const SizedBox(height: 6),
            if (!run.finished) ...[
              LinearProgressIndicator(
                value: run.fraction,
                minHeight: 4,
                color: AppColors.primary,
                backgroundColor: AppColors.greyLight,
              ),
              const SizedBox(height: 6),
              ..._hudRows(run, retained),
              const SizedBox(height: 4),
              _controls(ref, run),
            ] else
              ..._summaryRows(journey, run, retained),
          ],
        ),
      ),
    );
  }

  Widget _header(MockWalkRunState run) {
    return Row(
      children: [
        Expanded(
          child: Text(
            run.finished ? _Strings.resultTitle : _Strings.liveTitle,
            style: const TextStyle(
                color: AppColors.primaryDark, fontWeight: FontWeight.w800, fontSize: 11),
          ),
        ),
        if (run.paused && !run.finished)
          const Text(_Strings.pausedBadge,
              style: TextStyle(
                  color: AppColors.orange, fontWeight: FontWeight.w800, fontSize: 10)),
      ],
    );
  }

  List<Widget> _hudRows(MockWalkRunState run, int retained) {
    return [
      _row(_Strings.distanceLabel,
          '${run.walkedMeters.toStringAsFixed(0)} / ${run.totalMeters.toStringAsFixed(0)} m'),
      _row(_Strings.doneLabel, '${(run.fraction * 100).toStringAsFixed(0)}%'),
      _row(_Strings.timeLabel, '${_clock(run.elapsed)} / ${_clock(run.eta)}'),
      _row(_Strings.speedLabel, '${run.speedMps.toStringAsFixed(1)} m/s'),
      _row(_Strings.pointsLabel, '$retained ret / ${run.emitted} raw'),
    ];
  }

  /// Pause/resume + speed nudges. Safe no-ops if the run just ended — the
  /// notifier only forwards to a live runner.
  Widget _controls(WidgetRef ref, MockWalkRunState run) {
    final notifier = ref.read(mockWalkRunProvider.notifier);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _controlButton(
          icon: run.paused ? Icons.play_arrow : Icons.pause,
          tooltip: run.paused ? _Strings.resumeTooltip : _Strings.pauseTooltip,
          onPressed: run.paused ? notifier.resume : notifier.pause,
        ),
        Row(
          children: [
            _controlButton(
              icon: Icons.remove,
              tooltip: _Strings.slowerTooltip,
              onPressed: () => notifier.setSpeedMps(run.speedMps - _speedStepMps),
            ),
            _controlButton(
              icon: Icons.add,
              tooltip: _Strings.fasterTooltip,
              onPressed: () => notifier.setSpeedMps(run.speedMps + _speedStepMps),
            ),
          ],
        ),
      ],
    );
  }

  Widget _controlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      color: AppColors.primaryDark,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: onPressed,
    );
  }

  List<Widget> _summaryRows(JourneyState journey, MockWalkRunState run, int retained) {
    final ok = journey.rejectionCount == 0 && journey.claimedCount > 0;
    return [
      _row(_Strings.claimedLabel, '${journey.claimedCount} hexes'),
      _row(_Strings.rejectedLabel, '${journey.rejectionCount}'),
      _row(_Strings.pointsLabel, '$retained ret / ${run.emitted} raw'),
      const SizedBox(height: 4),
      Text(
        ok ? _Strings.statusOk : _Strings.statusCheck,
        style: TextStyle(
          color: ok ? AppColors.primaryDark : AppColors.orange,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
      if (journey.rejectionCount > 0 && journey.error != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(journey.error!,
              style: const TextStyle(color: AppColors.orange, fontSize: 10)),
        ),
    ];
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppColors.grey, fontSize: 11)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.dark, fontSize: 11, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
