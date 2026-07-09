/// Widget tests for the debug mock-walk panel (#29, reworked in #160).
///
/// The panel is presentation over two providers plus a control bridge, so these
/// seed each provider to a fixed state and assert the rendered read-out — the
/// live distance-based HUD, its pause/speed controls forwarding to the notifier,
/// and the counts-only OK / CHECK summary once the run finishes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myloop/features/dev/mock_walk_overlay.dart';
import 'package:myloop/features/journey/journey_controller.dart';
import 'package:myloop/shared/services/mock/mock_walk_run_state.dart';

/// Returns a fixed [JourneyState] regardless of controller logic.
class _FakeJourney extends JourneyController {
  _FakeJourney(this._seed);
  final JourneyState _seed;
  @override
  JourneyState build() => _seed;
}

/// Seeds a fixed [MockWalkRunState] and records control calls instead of
/// forwarding to a live runner.
class _FakeRun extends MockWalkRunNotifier {
  _FakeRun(this._seed);
  final MockWalkRunState _seed;
  final calls = <String>[];

  @override
  MockWalkRunState build() => _seed;

  @override
  void pause() => calls.add('pause');

  @override
  void resume() => calls.add('resume');

  @override
  void setSpeedMps(double value) => calls.add('speed:$value');
}

Future<_FakeRun> _pump(
  WidgetTester tester, {
  required MockWalkRunState run,
  required JourneyState journey,
}) async {
  final fake = _FakeRun(run);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mockWalkRunProvider.overrideWith(() => fake),
        journeyControllerProvider.overrideWith(() => _FakeJourney(journey)),
      ],
      child: const MaterialApp(home: Scaffold(body: MockWalkOverlay())),
    ),
  );
  return fake;
}

void main() {
  testWidgets('renders nothing when no run is active', (tester) async {
    await _pump(tester,
        run: const MockWalkRunState(), journey: const JourneyState());
    expect(find.textContaining('MOCK'), findsNothing);
  });

  testWidgets('shows the live distance-based HUD mid-run', (tester) async {
    await _pump(
      tester,
      run: MockWalkRunState(
          totalMeters: 200, walkedMeters: 50, emitted: 30, speedMps: 2.0, startedAt: DateTime.now()),
      journey: JourneyState(
        status: JourneyStatus.tracking,
        path: List.generate(4, (_) => [0.0, 0.0]),
      ),
    );
    expect(find.text('MOCK WALK'), findsOneWidget);
    expect(find.text('50 / 200 m'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('2.0 m/s'), findsOneWidget);
    expect(find.text('4 ret / 30 raw'), findsOneWidget);
  });

  testWidgets('pause button forwards to the notifier while walking', (tester) async {
    final fake = await _pump(
      tester,
      run: MockWalkRunState(
          totalMeters: 200, walkedMeters: 50, speedMps: 2.0, startedAt: DateTime.now()),
      journey: const JourneyState(status: JourneyStatus.tracking),
    );
    expect(find.text('PAUSED'), findsNothing);

    await tester.tap(find.byIcon(Icons.pause));
    expect(fake.calls, ['pause']);
  });

  testWidgets('paused run shows the badge and a resume button', (tester) async {
    final fake = await _pump(
      tester,
      run: MockWalkRunState(
          totalMeters: 200, walkedMeters: 50, speedMps: 2.0, paused: true, startedAt: DateTime.now()),
      journey: const JourneyState(status: JourneyStatus.tracking),
    );
    expect(find.text('PAUSED'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow));
    expect(fake.calls, ['resume']);
  });

  testWidgets('speed nudges forward a stepped value', (tester) async {
    final fake = await _pump(
      tester,
      run: MockWalkRunState(
          totalMeters: 200, walkedMeters: 50, speedMps: 2.0, startedAt: DateTime.now()),
      journey: const JourneyState(status: JourneyStatus.tracking),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.tap(find.byIcon(Icons.remove));
    expect(fake.calls, ['speed:2.5', 'speed:1.5']);
  });

  testWidgets('shows an OK summary once finished with claims and no rejections',
      (tester) async {
    await _pump(
      tester,
      run: MockWalkRunState(
          totalMeters: 200, walkedMeters: 200, emitted: 40, finished: true, startedAt: DateTime.now()),
      journey: JourneyState(
        status: JourneyStatus.tracking,
        claimedCount: 23,
        path: List.generate(41, (_) => [0.0, 0.0]),
      ),
    );
    expect(find.text('MOCK RESULT'), findsOneWidget);
    expect(find.text('23 hexes'), findsOneWidget);
    expect(find.text('STATUS: OK'), findsOneWidget);
    // Controls are gone once the run is over.
    expect(find.byIcon(Icons.pause), findsNothing);
  });

  testWidgets('flags CHECK when a batch was rejected', (tester) async {
    await _pump(
      tester,
      run: const MockWalkRunState(totalMeters: 200, walkedMeters: 200, finished: true),
      journey: const JourneyState(
        status: JourneyStatus.tracking,
        claimedCount: 5,
        rejectionCount: 2,
        error: 'batch rejected: speed too high',
      ),
    );
    expect(find.text('STATUS: CHECK'), findsOneWidget);
    expect(find.textContaining('speed too high'), findsOneWidget);
  });
}
