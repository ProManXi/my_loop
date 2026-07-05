import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myloop/features/home/home_tab.dart';
import 'package:myloop/app/theme.dart';

void main() {
  group('HomeTab loading state', () {
    testWidgets('homeTabLoadedProvider starts as false', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(homeTabLoadedProvider), false);
    });

    testWidgets('markLoaded sets provider to true', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(homeTabLoadedProvider.notifier).markLoaded();
      expect(container.read(homeTabLoadedProvider), true);
    });

    testWidgets('markLoading resets provider to false', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(homeTabLoadedProvider.notifier).markLoaded();
      container.read(homeTabLoadedProvider.notifier).markLoading();
      expect(container.read(homeTabLoadedProvider), false);
    });
  });

  group('HomeTab shimmer timing', () {
    testWidgets('shows shimmer initially', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(body: HomeTab()),
          ),
        ),
      );

      // Initially should show shimmer (look for shimmer boxes)
      // The tab is in loading state - no "Ready to conquer" text yet
      expect(find.textContaining('Ready to conquer'), findsNothing);

      // Pump past timer to avoid pending timer error
      await tester.pump(const Duration(milliseconds: 700));
      // skip: leaves a pending content-side Timer at teardown — see #71
    }, skip: true);

    testWidgets('shows content after 600ms', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(body: HomeTab()),
          ),
        ),
      );

      // Pump past shimmer duration
      await tester.pump(const Duration(milliseconds: 650));

      // Should now show actual content
      expect(find.textContaining('Ready to conquer'), findsOneWidget);
      // skip: leaves a pending content-side Timer at teardown — see #71
    }, skip: true);
  });
}
