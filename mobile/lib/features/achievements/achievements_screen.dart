/// Achievements tab â€” displays all player achievements with progress.
///
/// Shows a star count header and a paginated scrollable list of achievements
/// with tier progress bars, descriptions, and star indicators.
/// Loads 10 items at a time with lazy loading on scroll.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myloop/app/theme.dart';
import 'package:myloop/shared/models/achievements.dart';
import 'package:myloop/shared/state/profile_slice.dart';
import 'package:myloop/shared/widgets/shimmer_loading.dart';

/// The achievements tab showing achievements with lazy pagination.
class AchievementsScreen extends ConsumerStatefulWidget {
  const AchievementsScreen({super.key});

  @override
  ConsumerState<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends ConsumerState<AchievementsScreen> {
  static const _pageSize = 10;
  int _loadedCount = _pageSize;
  bool _isLoadingMore = false;
  bool _initialLoading = true;
  final _scrollController = ScrollController();

  /// Derives achievement progress from the user's live stats.
  ///
  /// Hex-based achievements use hexCount, walk-based use streak as a proxy.
  /// This will be replaced by a dedicated achievements API later.
  Map<String, int> _getProgress() {
    final profile = ref.watch(profileSliceProvider);
    return {
      'hex_1': profile.hexCount,
      'hex_2': profile.hexCount,
      'hex_3': profile.hexCount,
      'walk_1': profile.streak,
      'walk_2': profile.distanceKm.toInt(),
      'walk_3': profile.streak,
    };
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _initialLoading = false);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_isLoadingMore) return;
    if (_loadedCount >= achievements.length) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    if (currentScroll >= maxScroll - 200) {
      _loadMore();
    }
  }

  void _loadMore() {
    setState(() => _isLoadingMore = true);
    // Simulate network delay
    Future.delayed(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      setState(() {
        _loadedCount = (_loadedCount + _pageSize).clamp(0, achievements.length);
        _isLoadingMore = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = _getProgress();
    if (_initialLoading) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: ShimmerBox(width: 200, height: 32, borderRadius: 8)),
                    const SizedBox(width: 16),
                    ShimmerBox(width: 80, height: 28, borderRadius: 14),
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(child: ShimmerList(itemCount: 6, itemHeight: 80)),
              ],
            ),
          ),
        ),
      );
    }

    final totalStars = achievements.fold<int>(
      0, (sum, a) => sum + a.getStars(progress[a.id] ?? 0),
    );
    final hasMore = _loadedCount < achievements.length;

    // Sort achievements: most completed first (by stars desc, then progress % desc)
    final sorted = List<Achievement>.from(achievements)
      ..sort((a, b) {
        final starsA = a.getStars(progress[a.id] ?? 0);
        final starsB = b.getStars(progress[b.id] ?? 0);
        if (starsA != starsB) return starsB.compareTo(starsA);
        // Same stars â€” sort by progress toward next tier
        final progA = (progress[a.id] ?? 0) / a.tier3;
        final progB = (progress[b.id] ?? 0) / b.tier3;
        return progB.compareTo(progA);
      });

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Row(
                children: [
                  Expanded(child: Text('Achievements', style: Theme.of(context).textTheme.headlineLarge)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.yellow.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.hexagon, size: 16, color: AppColors.yellow),
                        const SizedBox(width: 4),
                        Text(
                          '$totalStars / ${achievements.length * 3}',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Achievement list â€” paginated
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                itemCount: _loadedCount + (hasMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= _loadedCount) {
                    // Loading indicator at the bottom
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: ShimmerList(itemCount: 3, itemHeight: 80),
                    );
                  }
                  return _AchievementTile(
                    achievement: sorted[index],
                    progress: progress[sorted[index].id] ?? 0,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single achievement row showing emoji, name, description, progress bar, and stars.
/// Tappable with ink ripple â€” opens bottom sheet with full details.
class _AchievementTile extends StatelessWidget {
  final Achievement achievement;
  final int progress;
  const _AchievementTile({required this.achievement, required this.progress});

  @override
  Widget build(BuildContext context) {
    final stars = achievement.getStars(progress);
    final nextTarget = stars == 0 ? achievement.tier1
        : stars == 1 ? achievement.tier2
        : stars == 2 ? achievement.tier3
        : achievement.tier3;
    final progressRatio = (progress / nextTarget).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showDetail(context, stars),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.greyLight, width: 2),
            ),
            child: Row(
              children: [
                Text(achievement.emoji, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(achievement.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(
                        achievement.description,
                        style: TextStyle(fontSize: 11, color: AppColors.grey),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$progress / $nextTarget ${achievement.unit}',
                        style: TextStyle(fontSize: 11, color: AppColors.dark, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progressRatio,
                          minHeight: 6,
                          backgroundColor: AppColors.greyLight,
                          valueColor: AlwaysStoppedAnimation(
                            stars >= 3 ? AppColors.yellow : AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  children: [
                    Row(
                      children: List.generate(3, (i) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: i < stars ? [
                              BoxShadow(
                                color: AppColors.yellow.withValues(alpha: 0.5),
                                blurRadius: 4,
                                spreadRadius: 0.5,
                              ),
                            ] : null,
                          ),
                          child: Icon(
                            Icons.hexagon,
                            size: i < stars ? 18 : 15,
                            color: i < stars ? AppColors.yellow : AppColors.greyLight,
                            shadows: [
                              Shadow(
                                color: i < stars
                                  ? AppColors.yellow.withValues(alpha: 0.6)
                                  : Colors.black.withValues(alpha: 0.15),
                                blurRadius: i < stars ? 3 : 1,
                              ),
                            ],
                          ),
                        ),
                      )),
                    ),
                    const SizedBox(height: 4),
                    Icon(Icons.chevron_right, size: 18, color: AppColors.grey),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showDetail(BuildContext context, int stars) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(achievement.emoji, style: const TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(achievement.name, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(achievement.description, style: TextStyle(color: AppColors.grey, fontSize: 14), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            _tierRow(1, 'Tier 1', '${achievement.tier1} ${achievement.unit}', stars >= 1),
            _tierRow(2, 'Tier 2', '${achievement.tier2} ${achievement.unit}', stars >= 2),
            _tierRow(3, 'Tier 3', '${achievement.tier3} ${achievement.unit}', stars >= 3),
            const SizedBox(height: 12),
            Text('Your progress: $progress ${achievement.unit}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _tierRow(int hexCount, String label, String target, bool achieved) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          ...List.generate(hexCount, (_) => Icon(
            Icons.hexagon, size: 14,
            color: achieved ? AppColors.yellow : AppColors.greyLight,
          )),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(target, style: TextStyle(color: achieved ? AppColors.primary : AppColors.grey)),
          const SizedBox(width: 8),
          Icon(achieved ? Icons.check_circle : Icons.radio_button_unchecked,
            color: achieved ? AppColors.primary : AppColors.greyLight, size: 20),
        ],
      ),
    );
  }
}