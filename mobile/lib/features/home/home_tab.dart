/// Home tab — the main dashboard players see after login.
///
/// Displays a welcome header with avatar, a daily challenge card with
/// progress, quick-stat tiles (streak, hexes, rank) with drill-down
/// bottom sheets, a Reels-style horizontal info carousel, and a rotating
/// "pro tip" card for engagement. Shows shimmer loading on initial load.
library;

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myloop/app/theme.dart';
import 'package:myloop/features/home/home_screen.dart';
import 'package:myloop/shared/constants/app_constants.dart';
import 'package:myloop/shared/models/exploration_neighborhood.dart';
import 'package:myloop/shared/models/daily_mission.dart';
import 'package:myloop/shared/models/achievement.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/shared/state/missions_slice.dart';
import 'package:myloop/shared/state/xp_slice.dart';
import 'package:myloop/shared/state/achievements_slice.dart';
import 'package:myloop/shared/state/exploration_slice.dart';
import 'package:myloop/shared/widgets/animated_hexagon.dart';
import 'package:myloop/shared/widgets/hex_trophy.dart';
import 'package:myloop/shared/widgets/retry_button.dart';
import 'package:myloop/shared/widgets/shimmer_loading.dart';
import 'package:go_router/go_router.dart';
import 'package:myloop/shared/services/notification_service.dart';

/// Rotating gameplay tips shown once per session to educate new players.
const _proTips = [
  'Walk a closed loop to capture all hexes inside it!',
  'Longer loops = more territory captured at once.',
  'You can steal other players\' hexes by walking through them.',
  'Walk during off-peak hours to claim territory unopposed.',
  'The closer your loop closes, the cleaner your capture.',
  'Small daily walks add up — consistency beats one big walk.',
  'Check the leaderboard to see who\'s near your territory.',
  'Walking 200m is the minimum to register a claim.',
  'Hexagons near landmarks are highly contested!',
  'Your trail captures hexes even without closing a loop.',
  'Walk in new areas to expand faster than defending old ones.',
  'A 500m loop can capture 20-30 hexagons at once!',
  'Morning walks have better GPS accuracy in urban areas.',
  'You keep territory even if you don\'t walk — unless someone takes it.',
  'Team up with friends to dominate a neighborhood!',
];

/// ─────────────────────────────────────────────────────────────────────────────
/// HOME TAB — Main scrollable dashboard content
/// ─────────────────────────────────────────────────────────────────────────────

/// Whether the home tab has finished its initial shimmer loading.
final homeTabLoadedProvider = NotifierProvider<_HomeTabLoadedNotifier, bool>(
  _HomeTabLoadedNotifier.new,
);

class _HomeTabLoadedNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void markLoaded() => state = true;
  void markLoading() => state = false;
}

/// The primary home tab showing player greeting, daily challenge, stats, and tips.
///
/// Shows shimmer placeholders briefly while data loads, then reveals content.
class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key});

  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> {
  late bool _isLoading;

  @override
  void initState() {
    super.initState();
    // Slices are hydrated on login — no manual refresh needed here.

    // Skip shimmer if we've already loaded once this session
    final alreadyLoaded = ref.read(homeTabLoadedProvider);
    if (alreadyLoaded) {
      _isLoading = false;
    } else {
      _isLoading = true;
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) {
          setState(() => _isLoading = false);
          ref.read(homeTabLoadedProvider.notifier).markLoaded();
        }
      });
    }
  }

  /// Builds the vertically scrollable dashboard layout.
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ShimmerBox(width: 48, height: 48, borderRadius: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ShimmerBox(height: 20, width: 160, borderRadius: 6),
                        const SizedBox(height: 8),
                        ShimmerBox(height: 14, width: 120, borderRadius: 6),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              ShimmerBox(height: 160),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: ShimmerBox(height: 80)),
                  const SizedBox(width: 12),
                  Expanded(child: ShimmerBox(height: 80)),
                  const SizedBox(width: 12),
                  Expanded(child: ShimmerBox(height: 80)),
                ],
              ),
              const SizedBox(height: 24),
              ShimmerBox(height: 72),
            ],
          ),
        ),
      );
    }

    // Stable tip: rotate daily rather than on every rebuild
    final dayIndex = DateTime.now().day % _proTips.length;
    final tip = _proTips[dayIndex];
    final profile = ref.watch(userProfileProvider);
    final myHexes = profile.hexCount;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: hex icon + greeting + tier badge
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Animated hex icon
                const AnimatedHexagon(size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hey, ${profile.displayName}! 👋',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      Text(
                        'Ready to conquer today?',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: AppColors.grey),
                      ),
                    ],
                  ),
                ),
                // Notification bell with unread badge
                Consumer(
                  builder: (context, ref, _) {
                    final unread = ref.watch(unreadCountProvider);
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IconButton(
                          icon: Icon(
                            unread > 0
                                ? Icons.notifications
                                : Icons.notifications_outlined,
                            color: AppColors.dark,
                            size: 26,
                          ),
                          onPressed: () => context.push('/notifications'),
                        ),
                        if (unread > 0)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              width: 16,
                              height: 16,
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  unread > 9 ? '9+' : '$unread',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(width: 4),
                // Tier badge — shows current hex tier + division
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HexTrophyBadge(
                      hexes: myHexes,
                      size: 40,
                      showLabel: false,
                      showProgress: false,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      HexTier.fullLabel(myHexes),
                      style: TextStyle(
                        color: HexTier.fromHexes(myHexes).color,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),

            // XP Progress bar — Clash of Clans style
            const _XpProgressBar(),
            const SizedBox(height: 28),

            // Daily challenge card
            const _DailyMissionsCard(),
            const SizedBox(height: 20),

            // Quick stats row (interactive)
            _QuickStats(),
            const SizedBox(height: 24),

            // Exploration progress for nearby neighborhoods
            const _ExplorationCard(),
            const SizedBox(height: 24),

            // Reels-style info carousel
            _InfoReels(),
            const SizedBox(height: 24),

            // Tip of the day
            _TipCard(tip: tip),
            const SizedBox(height: 80), // space for FAB
          ],
        ),
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// DAILY MISSIONS CARD
/// ─────────────────────────────────────────────────────────────────────────────

/// Provider that reads today's missions from the missions slice.
final dailyMissionsProvider = Provider<List<DailyMission>>((ref) {
  return ref.watch(missionsSliceProvider).missions;
});

/// Provider that reads XP info from the XP slice.
final xpInfoProvider = Provider<XpInfo>((ref) {
  final xp = ref.watch(xpSliceProvider);
  return XpInfo(
    totalXp: xp.totalXp,
    level: xp.level,
    progressXp: xp.progressXp,
    neededXp: xp.neededXp,
    progressPercent: xp.progressPercent,
  );
});

/// A card showing 3 daily missions with individual progress bars + XP rewards.
class _DailyMissionsCard extends ConsumerWidget {
  const _DailyMissionsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final missions = ref.watch(dailyMissionsProvider);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.primaryLight],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with countdown timer
          Row(
            children: [
              const Text('🎯', style: TextStyle(fontSize: 28)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Daily Missions',
                  style: TextStyle(
                    color: AppColors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              // Countdown to reset
              const _MissionCountdown(),
            ],
          ),
          const SizedBox(height: 16),

          // Missions list
          missions.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'Missions loading...',
                    style: TextStyle(color: AppColors.white, fontSize: 13),
                  ),
                )
              : Column(
                  children: missions
                      .map((m) => _MissionRow(mission: m))
                      .toList(),
                ),
        ],
      ),
    );
  }
}

class _MissionRow extends StatelessWidget {
  final DailyMission mission;
  const _MissionRow({required this.mission});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          // Mission icon
          Text(
            _iconForType(mission.type),
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(width: 10),
          // Description + progress
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mission.description,
                  style: TextStyle(
                    color: AppColors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    decoration: mission.isCompleted
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: mission.progressPercent,
                    minHeight: 5,
                    backgroundColor: AppColors.white.withValues(alpha: 0.2),
                    valueColor: AlwaysStoppedAnimation(
                      mission.isCompleted
                          ? const Color(0xFF4ADE80)
                          : AppColors.white.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // XP reward
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: mission.isCompleted
                  ? const Color(0xFF4ADE80).withValues(alpha: 0.3)
                  : AppColors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              mission.isCompleted ? '✓' : '+${mission.xpReward} XP',
              style: TextStyle(
                color: mission.isCompleted
                    ? const Color(0xFF4ADE80)
                    : AppColors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _iconForType(MissionType type) {
    return switch (type) {
      MissionType.captureHexes => '⬡',
      MissionType.walkDistance => '🚶',
      MissionType.stealHex => '⚔️',
      MissionType.exploreNewArea => '🗺️',
      MissionType.maintainStreak => '🔥',
      MissionType.captureInOneWalk => '💪',
    };
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// MISSION COUNTDOWN — time until daily reset (midnight UTC)
/// ─────────────────────────────────────────────────────────────────────────────

class _MissionCountdown extends StatefulWidget {
  const _MissionCountdown();

  @override
  State<_MissionCountdown> createState() => _MissionCountdownState();
}

class _MissionCountdownState extends State<_MissionCountdown> {
  late Duration _remaining;
  late final _ticker = Stream.periodic(const Duration(seconds: 30));
  StreamSubscription<void>? _tickerSub;

  @override
  void initState() {
    super.initState();
    _remaining = _calcRemaining();
    _tickerSub = _ticker.listen((_) {
      if (mounted) setState(() => _remaining = _calcRemaining());
    });
  }

  @override
  void dispose() {
    // Without this the periodic subscription (and its underlying timer) leaks
    // for the app's lifetime every time the home tab is rebuilt (#71).
    _tickerSub?.cancel();
    super.dispose();
  }

  Duration _calcRemaining() {
    final now = DateTime.now().toUtc();
    final midnight = DateTime.utc(now.year, now.month, now.day + 1);
    return midnight.difference(now);
  }

  @override
  Widget build(BuildContext context) {
    final h = _remaining.inHours;
    final m = _remaining.inMinutes.remainder(60);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.timer_outlined,
            size: 12,
            color: AppColors.white.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 4),
          Text(
            '${h}h ${m}m',
            style: TextStyle(
              color: AppColors.white.withValues(alpha: 0.9),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// XP PROGRESS BAR — Clash of Clans style (full width under header)
/// ─────────────────────────────────────────────────────────────────────────────

class _XpProgressBar extends ConsumerWidget {
  const _XpProgressBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final xp = ref.watch(xpInfoProvider);

    final progress = xp.neededXp > 0
        ? (xp.progressXp / xp.neededXp).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF6366F1).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          // Level circle (left side — "where we are")
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.4),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Center(
              child: Text(
                '${xp.level}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Progress bar (middle)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // XP text above bar
                Row(
                  children: [
                    Text(
                      '${xp.progressXp}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      ' / ${xp.neededXp} XP',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // The bar itself
                Stack(
                  children: [
                    // Background track
                    Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    // Filled portion with gradient
                    FractionallySizedBox(
                      widthFactor: progress,
                      child: Container(
                        height: 10,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF6366F1), Color(0xFFA78BFA)],
                          ),
                          borderRadius: BorderRadius.circular(5),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF8B5CF6,
                              ).withValues(alpha: 0.5),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Next level (right side — "where we need to go")
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.08),
              border: Border.all(
                color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                width: 2,
              ),
            ),
            child: Center(
              child: Text(
                '${xp.level + 1}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// ACHIEVEMENTS CARD
/// ─────────────────────────────────────────────────────────────────────────────

/// Provider that reads achievements from the achievements slice.
final achievementsProvider = Provider<List<Achievement>>((ref) {
  return ref.watch(achievementsSliceProvider).achievements;
});

/// Shows recently unlocked achievements and next closest ones.
class _AchievementsCard extends ConsumerWidget {
  const _AchievementsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final achievements = ref.watch(achievementsProvider);

    if (achievements.isEmpty) return const SizedBox.shrink();

    final unlocked = achievements.where((a) => a.unlocked).toList();
    final locked = achievements.where((a) => !a.unlocked).toList();
    // Show top 3 closest-to-unlock
    locked.sort((a, b) => b.progress.compareTo(a.progress));
    final nextUp = locked.take(3).toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF8B5CF6).withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🏆', style: TextStyle(fontSize: 24)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Achievements',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${unlocked.length}/${achievements.length}',
                  style: const TextStyle(
                    color: Color(0xFF8B5CF6),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (unlocked.isNotEmpty) ...[
            const SizedBox(height: 14),
            // Recently unlocked (show last 3)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: unlocked.reversed
                  .take(5)
                  .map(
                    (a) => _AchievementBadge(
                      icon: a.icon,
                      name: a.name,
                      unlocked: true,
                    ),
                  )
                  .toList(),
            ),
          ],
          if (nextUp.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Next up',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ...nextUp.map((a) => _AchievementProgressRow(achievement: a)),
          ],
        ],
      ),
    );
  }
}

class _AchievementBadge extends StatelessWidget {
  final String icon;
  final String name;
  final bool unlocked;
  const _AchievementBadge({
    required this.icon,
    required this.name,
    required this.unlocked,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: name,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: unlocked
              ? const Color(0xFF8B5CF6).withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: unlocked
                ? const Color(0xFF8B5CF6).withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(icon, style: const TextStyle(fontSize: 20)),
      ),
    );
  }
}

class _AchievementProgressRow extends StatelessWidget {
  final Achievement achievement;
  const _AchievementProgressRow({required this.achievement});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(achievement.icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  achievement.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: achievement.progress,
                    minHeight: 4,
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF8B5CF6)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${(achievement.progress * 100).toInt()}%',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// QUICK STATS ROW
/// ─────────────────────────────────────────────────────────────────────────────

/// Row of tappable stat tiles that open detail bottom sheets.
///
/// Each tile shows an emoji, a value, and a label. Tapping reveals
/// historical data (streak history, hex history) or rank scope options.
class _QuickStats extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProfileProvider);
    return Row(
      children: [
        Expanded(
          child: _MiniStat(
            emoji: '🔥',
            value: '${user.streak}',
            label: 'Streak',
            onTap: () => _showStreakHistory(context, user),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MiniStat(
            emoji: '⬡',
            value: '${user.hexCount}',
            label: 'Hexes',
            onTap: () => _showHexHistory(context, user),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MiniStat(
            emoji: '🏆',
            value: '#${user.rank}',
            label: 'Rank',
            onTap: () => _showRankSelector(context, ref),
          ),
        ),
      ],
    );
  }

  /// Opens a bottom sheet showing the daily streak history.
  void _showStreakHistory(BuildContext context, UserProfile user) {
    final currentStreak = user.streak;
    final isNewUser = user.distanceKm == 0 && currentStreak == 0;
    final streakBroken = !isNewUser && currentStreak == 0;

    homeFabVisible.value = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.4,
        maxChildSize: 0.85,
        expand: false,
        builder: (context, scroll) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.greyLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Streak hero - new user / broken / active
              if (isNewUser) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF00D4AA), Color(0xFF00897B)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const _ReadyHexFace(size: 52),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Ready to Run!',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Start your first walk to begin a streak',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (streakBroken) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF636E72), Color(0xFF2D3436)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const _SadHexFace(size: 52),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Streak Lost!',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Walk today to start a new one',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFFA502), Color(0xFFFF6348)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const Text('🔥', style: TextStyle(fontSize: 48)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$currentStreak Day Streak',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Keep walking daily!',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Text(
                'Daily History',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _StreakHistoryLazy(
                  scroll: scroll,
                  streakDays: currentStreak,
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((_) => homeFabVisible.value = true);
  }

  /// Opens a bottom sheet showing hex earned/lost per day + tier scale.
  void _showHexHistory(BuildContext context, UserProfile user) {
    final userHexes = user.hexCount;
    final tier = HexTier.fromHexes(userHexes);
    final division = HexTier.divisionFromHexes(userHexes);
    final divLabel = HexTier.fullLabel(userHexes);
    // Calculate next milestone (next division or next tier)
    final nextTier = tier.next;
    final tierRange = nextTier != null
        ? (nextTier.threshold - tier.threshold).toDouble()
        : 5000.0;
    final divSize = tierRange / 4;
    final nextDivThreshold = (tier.threshold + division * divSize).round();
    final toNextDiv = nextDivThreshold - userHexes;
    const romans = ['I', 'II', 'III', 'IV'];
    final nextLabel = division < 4
        ? '${tier.label} ${romans[division]}' // next division in same tier
        : (nextTier?.label ?? 'Max'); // next tier

    homeFabVisible.value = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scroll) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.greyLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Trophy hero: current badge | info | target badge
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  HexTrophyBadge(
                    hexes: userHexes,
                    size: 64,
                    showProgress: false,
                    showLabel: false,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$userHexes Hexes',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          divLabel,
                          style: TextStyle(
                            color: tier.color,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        if (toNextDiv > 0)
                          Text(
                            '$toNextDiv more for $nextLabel',
                            style: TextStyle(
                              color: AppColors.grey,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (nextTier != null || division < 4) ...[
                    const SizedBox(width: 12),
                    Opacity(
                      opacity: 0.8,
                      child: HexTrophyBadge(
                        hexes: nextDivThreshold,
                        size: 44,
                        showProgress: false,
                        showLabel: true,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              // Division progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: HexTier.divisionProgress(userHexes),
                  minHeight: 10,
                  backgroundColor: tier.color.withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation(tier.color),
                ),
              ),
              const SizedBox(height: 20),
              // Full tier scale
              Text(
                'All Tiers',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              HexTierShowcase(currentHexes: userHexes),
              const SizedBox(height: 20),
              Text(
                'Hex History',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Expanded(child: _HexHistoryLazy(scroll: scroll)),
            ],
          ),
        ),
      ),
    ).then((_) => homeFabVisible.value = true);
  }

  /// Opens a bottom sheet showing rank at different geographic scopes.
  void _showRankSelector(BuildContext context, WidgetRef ref) {
    final user = ref.read(userProfileProvider);
    homeFabVisible.value = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) =>
          _RankSheet(cityRank: user.rank, userId: user.userId),
    ).then((_) => homeFabVisible.value = true);
  }
}

/// Bottom sheet that fetches and displays rank across all scopes.
class _RankSheet extends StatefulWidget {
  final int cityRank;
  final String? userId;
  const _RankSheet({required this.cityRank, this.userId});

  @override
  State<_RankSheet> createState() => _RankSheetState();
}

class _RankSheetState extends State<_RankSheet> {
  int _countryRank = 0;
  int _worldRank = 0;
  bool _loading = true;
  // True when the country/world ranks couldn't be fetched because the backend
  // was unreachable. We then show an offline note instead of a misleading "—"
  // that looks like the user is simply unranked (issue #36).
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _fetchRanks();
  }

  /// Re-show the loading spinner and refetch on an in-place retry (issue #49).
  /// Separate from [_fetchRanks] so the initState call path does not call
  /// setState during widget initialisation.
  void _retryRanks() {
    setState(() {
      _loading = true;
      _offline = false;
    });
    _fetchRanks();
  }

  Future<void> _fetchRanks() async {
    if (widget.userId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final container = ProviderScope.containerOf(context);
      final api = container.read(apiServiceProvider);
      final results = await Future.wait([
        api.getLeaderboard(
          lat: 0,
          lng: 0,
          userId: widget.userId,
          scope: 'country',
        ),
        api.getLeaderboard(
          lat: 0,
          lng: 0,
          userId: widget.userId,
          scope: 'world',
        ),
      ]);
      if (mounted) {
        setState(() {
          _countryRank = results[0].myRank ?? 0;
          _worldRank = results[1].myRank ?? 0;
          _loading = false;
          _offline = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _offline = isServerUnreachable(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rank = widget.cityRank > 0 ? widget.cityRank : 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.greyLight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Rank hero card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFFD93D), Color(0xFFF59E0B)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Text('🏆', style: TextStyle(fontSize: 44)),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '#$rank in Your City',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      rank <= 3 && rank > 0
                          ? 'Podium finish! 🥇'
                          : 'Keep walking to climb!',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Your Ranking',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          _RankOption(scope: 'City', rank: rank, emoji: '🏙️'),
          if (_offline)
            _RankOfflineNote(onRetry: _retryRanks)
          else ...[
            _RankOption(
              scope: 'Country',
              rank: _loading ? -1 : _countryRank,
              emoji: '🌍',
            ),
            _RankOption(
              scope: 'World',
              rank: _loading ? -1 : _worldRank,
              emoji: '🌐',
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// A geographic scope rank display row used in the rank bottom sheet.
class _RankOption extends StatelessWidget {
  final String scope;
  final int rank; // -1 = loading, 0 = unknown
  final String emoji;
  const _RankOption({
    required this.scope,
    required this.rank,
    required this.emoji,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.snow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.greyLight, width: 2),
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              scope,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
          rank == -1
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  rank > 0 ? '#$rank' : '—',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    color: AppColors.primary,
                  ),
                ),
        ],
      ),
    );
  }
}

/// Inline offline note shown in the rank sheet in place of the Country/World
/// rows when those ranks couldn't be fetched (issue #36). The City rank still
/// renders from the cached profile, so only the network-backed scopes are
/// replaced.
class _RankOfflineNote extends StatelessWidget {
  /// Re-runs the country/world rank fetch when tapped (issue #49).
  final VoidCallback onRetry;
  const _RankOfflineNote({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.snow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.greyLight, width: 2),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, size: 22, color: AppColors.grey),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              AppConstants.offlineRankingMessage,
              style: const TextStyle(
                color: AppColors.grey,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          RetryButton(onPressed: onRetry),
        ],
      ),
    );
  }
}

/// A single tappable stat tile with emoji, value, and label.
///
/// Used in the [_QuickStats] row. The [onTap] callback opens the
/// corresponding detail bottom sheet.
class _MiniStat extends StatelessWidget {
  final String emoji;
  final String value;
  final String label;
  final VoidCallback onTap;
  const _MiniStat({
    required this.emoji,
    required this.value,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.greyLight, width: 2),
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// EXPLORATION CARD
/// ─────────────────────────────────────────────────────────────────────────────

/// Provider that reads exploration stats from the exploration slice.
final explorationProvider = Provider<List<ExplorationNeighborhood>>((ref) {
  return ref.watch(explorationSliceProvider).neighborhoods;
});

/// Shows exploration % for the user's nearest neighborhood.
class _ExplorationCard extends ConsumerWidget {
  const _ExplorationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final neighborhoods = ref.watch(explorationProvider);

    if (neighborhoods.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF00D4AA).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFF00D4AA).withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            const Text('🗺️', style: TextStyle(fontSize: 24)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Area Exploration',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  Text(
                    'Start walking to explore your neighborhood!',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.dark.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final sorted = [...neighborhoods]
      ..sort((a, b) => b.percent.compareTo(a.percent));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('🗺️', style: TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
            const Text(
              'Area Exploration',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const Spacer(),
            Text(
              '${sorted.length} area${sorted.length > 1 ? 's' : ''}',
              style: TextStyle(fontSize: 12, color: AppColors.grey),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 100,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) =>
                _NeighborhoodTile(neighborhood: sorted[i]),
          ),
        ),
      ],
    );
  }
}

class _NeighborhoodTile extends StatelessWidget {
  final ExplorationNeighborhood neighborhood;
  const _NeighborhoodTile({required this.neighborhood});

  @override
  Widget build(BuildContext context) {
    final pct = neighborhood.percent;
    final color = pct >= 75
        ? const Color(0xFF00D4AA)
        : pct >= 40
        ? AppColors.primary
        : const Color(0xFFF59E0B);

    return Container(
      width: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            neighborhood.areaName.isNotEmpty ? neighborhood.areaName : 'Area',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Row(
            children: [
              Icon(Icons.hexagon_outlined, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                '${neighborhood.ownedCount}/${neighborhood.totalCount}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ],
          ),
          Text(
            '${pct.toStringAsFixed(0)}% explored',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.dark.withValues(alpha: 0.6),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct / 100.0,
              minHeight: 5,
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// TIP CARD
/// ─────────────────────────────────────────────────────────────────────────────

/// Displays a random gameplay tip with a lightbulb emoji.
///
/// The tip is randomly selected from [_proTips] each time the home tab rebuilds.
class _TipCard extends StatelessWidget {
  final String tip;
  const _TipCard({required this.tip});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.blue.withValues(alpha: 0.3),
          width: 2,
        ),
      ),
      child: Row(
        children: [
          const Text('💡', style: TextStyle(fontSize: 28)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pro tip',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
                Text(
                  tip,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.dark.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// INFO REELS — Instagram-style horizontal scrollable cards
/// ─────────────────────────────────────────────────────────────────────────────

/// Horizontal carousel of engaging hook cards — personalized based on user state.
/// Big bold text, urgency hooks, vibrant gradients.
class _InfoReels extends ConsumerStatefulWidget {
  @override
  ConsumerState<_InfoReels> createState() => _InfoReelsState();
}

class _InfoReelsState extends ConsumerState<_InfoReels> {
  final _controller = PageController(viewportFraction: 0.85);
  int _currentPage = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// New user reels — onboarding/tutorial focused
  static const _newUserReels = [
    _ReelData(
      emoji: '👋',
      title: 'Welcome to MyLoop!',
      body:
          'Walk around your neighborhood to capture hex territory. The more you walk, the more you own!',
      gradient: [Color(0xFF00D4AA), Color(0xFF00897B)],
      hook: 'GET STARTED',
    ),
    _ReelData(
      emoji: '🚶',
      title: 'How to capture territory',
      body:
          'Start a journey, walk at least 200m, and every hex you walk through becomes yours!',
      gradient: [Color(0xFF6C5CE7), Color(0xFF4834D4)],
      hook: 'LEARN MORE',
    ),
    _ReelData(
      emoji: '⭕',
      title: 'Pro move: Close a loop!',
      body:
          'Walk in a closed loop and capture EVERY hex inside it — not just the ones you walk through.',
      gradient: [Color(0xFF0984E3), Color(0xFF0652DD)],
      hook: 'PRO TIP',
    ),
    _ReelData(
      emoji: '⚔️',
      title: 'Steal others\' territory!',
      body:
          'Walk through hexes owned by other players to steal them. They can do the same to you!',
      gradient: [Color(0xFFE17055), Color(0xFFB33B27)],
      hook: 'PVP MODE',
    ),
    _ReelData(
      emoji: '🔥',
      title: 'Build your streak!',
      body:
          'Walk every day to build a streak. Longer streaks unlock achievements and bragging rights.',
      gradient: [Color(0xFFFFA502), Color(0xFFFF6348)],
      hook: 'DAILY GOAL',
    ),
  ];

  /// Existing user reels — competitive/engagement focused
  static const _existingUserReels = [
    _ReelData(
      emoji: '⚡',
      title: 'Someone\'s near your turf!',
      body:
          'Other players are active nearby. Walk now to defend or expand your territory!',
      gradient: [Color(0xFF6C5CE7), Color(0xFF4834D4)],
      hook: 'DEFEND NOW',
    ),
    _ReelData(
      emoji: '🗺️',
      title: 'Unclaimed land nearby',
      body:
          'Free territory waiting! Be the first to walk there and claim it all.',
      gradient: [Color(0xFF00D4AA), Color(0xFF00897B)],
      hook: 'GRAB FREE HEXES',
    ),
    _ReelData(
      emoji: '🏆',
      title: 'Climb the leaderboard!',
      body:
          'One good walk could move you up several ranks. Check who\'s ahead!',
      gradient: [Color(0xFFF59E0B), Color(0xFFD97706)],
      hook: 'CLIMB RANKS',
    ),
    _ReelData(
      emoji: '⚔️',
      title: 'Revenge is sweet!',
      body:
          'Someone took your hexes? Walk through their territory to steal them back!',
      gradient: [Color(0xFFE17055), Color(0xFFB33B27)],
      hook: 'FIGHT BACK',
    ),
    _ReelData(
      emoji: '🎯',
      title: 'Close a loop for 10x hexes!',
      body:
          'Walking a closed loop captures every hex inside. Bigger loop = more territory.',
      gradient: [Color(0xFF0984E3), Color(0xFF0652DD)],
      hook: 'PRO TIP',
    ),
    _ReelData(
      emoji: '💎',
      title: 'Tier up with consistency!',
      body:
          'Daily walks compound fast. Keep your streak alive for faster tier progress.',
      gradient: [Color(0xFF60A5FA), Color(0xFF2563EB)],
      hook: 'TIER UP',
    ),
  ];

  List<_ReelData> get _reels {
    final profile = ref.watch(userProfileProvider);
    return profile.hexCount == 0 && profile.streak == 0
        ? _newUserReels
        : _existingUserReels;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Row(
            children: [
              const AnimatedHexagon(size: 28),
              const SizedBox(width: 8),
              Text(
                'What\'s Happening',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 180,
          child: PageView.builder(
            controller: _controller,
            itemCount: _reels.length,
            onPageChanged: (i) => setState(() => _currentPage = i),
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _ReelCard(data: _reels[index]),
            ),
          ),
        ),
        const SizedBox(height: 10),
        // Page indicators
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            _reels.length,
            (i) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == _currentPage ? 20 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == _currentPage
                    ? AppColors.primary
                    : AppColors.greyLight,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Data model for a single reel card.
class _ReelData {
  final String emoji;
  final String title;
  final String body;
  final List<Color> gradient;
  final String hook;
  const _ReelData({
    required this.emoji,
    required this.title,
    required this.body,
    required this.gradient,
    required this.hook,
  });
}

/// A single reel card — gradient background with hook badge, emoji, title, and CTA.
class _ReelCard extends StatelessWidget {
  final _ReelData data;
  const _ReelCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: data.gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: data.gradient[0].withValues(alpha: 0.4),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hook badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              data.hook,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(data.emoji, style: const TextStyle(fontSize: 28)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  data.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Text(
              data.body,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 12,
                height: 1.3,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // CTA arrow
          Align(
            alignment: Alignment.bottomRight,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.arrow_forward,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// SAD HEX FACE (streak broken)
/// ─────────────────────────────────────────────────────────────────────────────

/// A sad hexagon face with big crying eyes — shows when streak is lost.
class _SadHexFace extends StatefulWidget {
  final double size;
  const _SadHexFace({this.size = 48});

  @override
  State<_SadHexFace> createState() => _SadHexFaceState();
}

class _SadHexFaceState extends State<_SadHexFace>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(painter: _SadHexPainter(wobble: _ctrl.value)),
      ),
    );
  }
}

class _SadHexPainter extends CustomPainter {
  final double wobble;
  _SadHexPainter({required this.wobble});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.44;
    canvas.save();
    canvas.translate(cx, cy);

    // Hex body (grey)
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = (math.pi / 3) * i - math.pi / 2;
      if (i == 0) {
        path.moveTo(r * math.cos(a), r * math.sin(a));
      } else {
        path.lineTo(r * math.cos(a), r * math.sin(a));
      }
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF636E72), Color(0xFF2D3436)],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: r)),
    );

    // Eyes (big, sad)
    final eyeY = -r * 0.15 + wobble * 2;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(-r * 0.25, eyeY),
        width: r * 0.25,
        height: r * 0.3,
      ),
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      Offset(-r * 0.25, eyeY + r * 0.04),
      r * 0.08,
      Paint()..color = const Color(0xFF2D3436),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(r * 0.25, eyeY),
        width: r * 0.25,
        height: r * 0.3,
      ),
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      Offset(r * 0.25, eyeY + r * 0.04),
      r * 0.08,
      Paint()..color = const Color(0xFF2D3436),
    );

    // Sad mouth (frown)
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(0, r * 0.35),
        width: r * 0.5,
        height: r * 0.3,
      ),
      math.pi * 0.1,
      math.pi * 0.8,
      false,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );

    // Tear drops
    final tearY = eyeY + r * 0.2 + wobble * 4;
    canvas.drawCircle(
      Offset(-r * 0.28, tearY),
      r * 0.05,
      Paint()..color = const Color(0xFF74B9FF),
    );
    canvas.drawCircle(
      Offset(r * 0.3, tearY + 2),
      r * 0.04,
      Paint()..color = const Color(0xFF74B9FF),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SadHexPainter old) => wobble != old.wobble;
}

/// Animated hex face for new users — energetic, ready-to-run pose with sparkle eyes.
class _ReadyHexFace extends StatefulWidget {
  final double size;
  const _ReadyHexFace({this.size = 48});

  @override
  State<_ReadyHexFace> createState() => _ReadyHexFaceState();
}

class _ReadyHexFaceState extends State<_ReadyHexFace>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(painter: _ReadyHexPainter(bounce: _ctrl.value)),
      ),
    );
  }
}

class _ReadyHexPainter extends CustomPainter {
  final double bounce;
  _ReadyHexPainter({required this.bounce});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.44;
    final bounceOffset = bounce * 3;
    canvas.save();
    canvas.translate(cx, cy - bounceOffset);

    // Hex body (vibrant green)
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = (math.pi / 3) * i - math.pi / 2;
      if (i == 0) {
        path.moveTo(r * math.cos(a), r * math.sin(a));
      } else {
        path.lineTo(r * math.cos(a), r * math.sin(a));
      }
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF00D4AA), Color(0xFF00897B)],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: r)),
    );

    // Sparkle eyes (star-shaped pupils)
    final eyeY = -r * 0.15;
    canvas.drawCircle(
      Offset(-r * 0.25, eyeY),
      r * 0.12,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      Offset(r * 0.25, eyeY),
      r * 0.12,
      Paint()..color = Colors.white,
    );
    // Star pupils
    final starPaint = Paint()..color = const Color(0xFF2D3436);
    canvas.drawCircle(Offset(-r * 0.25, eyeY), r * 0.06, starPaint);
    canvas.drawCircle(Offset(r * 0.25, eyeY), r * 0.06, starPaint);
    // Sparkle dots
    final sparkPaint = Paint()..color = Colors.white;
    canvas.drawCircle(
      Offset(-r * 0.22, eyeY - r * 0.04),
      r * 0.025,
      sparkPaint,
    );
    canvas.drawCircle(Offset(r * 0.28, eyeY - r * 0.04), r * 0.025, sparkPaint);

    // Big excited grin
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(0, r * 0.25),
        width: r * 0.6,
        height: r * 0.4,
      ),
      0,
      math.pi,
      false,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );

    // Running motion lines (left side)
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(-r * 0.8, r * 0.1),
      Offset(-r * 0.55, r * 0.1),
      linePaint,
    );
    canvas.drawLine(
      Offset(-r * 0.75, r * 0.3),
      Offset(-r * 0.5, r * 0.3),
      linePaint,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ReadyHexPainter old) => bounce != old.bounce;
}

/// ─────────────────────────────────────────────────────────────────────────────
/// HEX HISTORY LAZY (shows real claim history from API)
/// ─────────────────────────────────────────────────────────────────────────────

class _HexHistoryLazy extends ConsumerStatefulWidget {
  final ScrollController scroll;
  const _HexHistoryLazy({required this.scroll});

  @override
  ConsumerState<_HexHistoryLazy> createState() => _HexHistoryLazyState();
}

class _HexHistoryLazyState extends ConsumerState<_HexHistoryLazy> {
  List<Map<String, dynamic>> _claims = [];
  int _visibleCount = 5;
  bool _loadingMore = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  Future<void> _fetchHistory() async {
    final profile = ref.read(userProfileProvider);
    if (profile.userId == null) {
      if (mounted)
        setState(() {
          _loading = false;
        });
      return;
    }
    try {
      final api = ref.read(apiServiceProvider);
      final history = await api.getClaimHistory(profile.userId!);
      if (mounted)
        setState(() {
          _claims = history;
          _loading = false;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = e.toString();
        });
    }
  }

  void _loadMore() {
    if (_loadingMore || _visibleCount >= _claims.length) return;
    setState(() => _loadingMore = true);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted)
        setState(() {
          _visibleCount = (_visibleCount + 5).clamp(0, _claims.length);
          _loadingMore = false;
        });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
        child: Text(
          'Could not load history',
          style: TextStyle(color: AppColors.grey, fontSize: 13),
        ),
      );
    }
    if (_claims.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('⬡', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 12),
            Text(
              'No hex history yet',
              style: TextStyle(
                color: AppColors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Start walking to capture territory!',
              style: TextStyle(color: AppColors.grey, fontSize: 12),
            ),
          ],
        ),
      );
    }
    final visible = _claims.take(_visibleCount).toList();
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 50) {
          _loadMore();
        }
        return false;
      },
      child: ListView.builder(
        controller: widget.scroll,
        itemCount: visible.length + (_loadingMore ? 3 : 0),
        itemBuilder: (context, index) {
          if (index >= visible.length) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ShimmerBox(height: 72, borderRadius: 12),
            );
          }
          final claim = visible[index];
          final earned = (claim['cellCount'] as num?)?.toInt() ?? 0;
          final areaM2 = (claim['areaM2'] as num?)?.toDouble() ?? 0;
          final rawDate = claim['date'] as String? ?? '';
          final dateStr = rawDate.isNotEmpty
              ? _formatDate(DateTime.tryParse(rawDate))
              : 'Unknown date';
          final areaStr = areaM2 >= 1000000
              ? '${(areaM2 / 1000000).toStringAsFixed(2)} km²'
              : '${(areaM2 / 1000).toStringAsFixed(1)} k m²';

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.snow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.greyLight, width: 1.5),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(
                    child: Text('⬡', style: TextStyle(fontSize: 20)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dateStr,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        areaStr,
                        style: const TextStyle(
                          color: AppColors.grey,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '+$earned ⬡',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return 'Unknown date';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// STREAK HISTORY LAZY (shows 10 then loads more)
/// ─────────────────────────────────────────────────────────────────────────────

class _StreakHistoryLazy extends StatefulWidget {
  final ScrollController scroll;
  final int streakDays;
  const _StreakHistoryLazy({required this.scroll, required this.streakDays});

  @override
  State<_StreakHistoryLazy> createState() => _StreakHistoryLazyState();
}

class _StreakHistoryLazyState extends State<_StreakHistoryLazy> {
  List<Map<String, dynamic>> _days = [];
  int _visibleCount = 7;
  bool _loadingMore = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  Future<void> _fetchHistory() async {
    // TODO: Replace with real API call when daily walk history endpoint exists
    // For now, show empty state for users with no walk data
    if (mounted)
      setState(() {
        _loading = false;
      });
  }

  void _loadMore() {
    if (_loadingMore || _visibleCount >= _days.length) return;
    setState(() => _loadingMore = true);
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() {
          _visibleCount = (_visibleCount + 7).clamp(0, _days.length);
          _loadingMore = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_days.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🚶', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 12),
            Text(
              'No walk history yet',
              style: TextStyle(
                color: AppColors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Complete a walk to start your streak!',
              style: TextStyle(color: AppColors.grey, fontSize: 12),
            ),
          ],
        ),
      );
    }
    final visible = _days.take(_visibleCount).toList();
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // Auto-load more when scrolling near the bottom
        if (notification is ScrollUpdateNotification &&
            notification.metrics.pixels >
                notification.metrics.maxScrollExtent - 100) {
          _loadMore();
        }
        return false;
      },
      child: ListView.builder(
        controller: widget.scroll,
        itemCount: visible.length + (_loadingMore ? 3 : 0),
        itemBuilder: (context, index) {
          // Shimmer placeholders while loading more
          if (index >= visible.length) {
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.snow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.greyLight.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 12,
                          width: 80,
                          color: AppColors.greyLight.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          height: 10,
                          width: 140,
                          color: AppColors.greyLight.withValues(alpha: 0.3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
          final day = visible[index];
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.snow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.greyLight, width: 1.5),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Center(
                    child: Text('🔥', style: TextStyle(fontSize: 20)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        day['date'] as String,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${day['hexes']} hexes · ${day['distance']} · ${day['time']}',
                        style: TextStyle(fontSize: 12, color: AppColors.grey),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '✓',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
