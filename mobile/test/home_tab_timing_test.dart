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

      // Advance past the 600ms shimmer delay so content mounts.
      await tester.pump(const Duration(milliseconds: 700));

      // Content has pulsing children with repeat() animation controllers; unmount
      // the tree so those tickers dispose and no timer is left pending (#71).
      await tester.pumpWidget(const SizedBox());
    });

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

      // Unmount so the content's repeat() animation controllers dispose and
      // leave no pending timer at teardown (#71).
      await tester.pumpWidget(const SizedBox());
    });
  });
}
