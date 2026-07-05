/// Leaderboard screen — displays player rankings with Local/City/Country tabs.
///
/// Shows a podium visualization for the top 3 players and a scrollable
/// list for remaining ranks. Each scope fetches from the API independently.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:myloop/app/theme.dart';
import 'package:myloop/shared/models/leaderboard_entry.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/shared/widgets/avatar_widget.dart';
import 'package:myloop/shared/widgets/hex_trophy.dart';
import 'package:myloop/shared/widgets/shimmer_loading.dart';

/// Scoped leaderboard providers — one per tab.
final cityLeaderboardProvider = FutureProvider.autoDispose<List<LeaderboardEntry>>((ref) async {
  final api = ref.read(apiServiceProvider);
  final profile = ref.read(userProfileProvider);
  final response = await api.getLeaderboard(lat: 0, lng: 0, userId: profile.userId, scope: 'city');
  if (response.myRank != null) {
    ref.read(userProfileProvider.notifier).updateStats(rank: response.myRank);
  }
  return response.top;
});

final countryLeaderboardProvider = FutureProvider.autoDispose<List<LeaderboardEntry>>((ref) async {
  final api = ref.read(apiServiceProvider);
  final profile = ref.read(userProfileProvider);
  final response = await api.getLeaderboard(lat: 0, lng: 0, userId: profile.userId, scope: 'country');
  return response.top;
});

final worldLeaderboardProvider = FutureProvider.autoDispose<List<LeaderboardEntry>>((ref) async {
  final api = ref.read(apiServiceProvider);
  final profile = ref.read(userProfileProvider);
  final response = await api.getLeaderboard(lat: 0, lng: 0, userId: profile.userId, scope: 'world');
  return response.top;
});

/// ─────────────────────────────────────────────────────────────────────────────
/// LEADERBOARD SCREEN
/// ─────────────────────────────────────────────────────────────────────────────

class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _scopes = ['City', 'Country', 'World'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _scopes.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            Text('🏆 Leaderboard', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            // Scope tabs
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.snow,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: Colors.transparent,
                  indicator: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  labelColor: AppColors.white,
                  unselectedLabelColor: AppColors.grey,
                  labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  tabs: _scopes.map((s) => Tab(text: s)).toList(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _ScopedLeaderboard(provider: cityLeaderboardProvider),
                  _ScopedLeaderboard(provider: countryLeaderboardProvider),
                  _ScopedLeaderboard(provider: worldLeaderboardProvider),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single scoped leaderboard tab (local/city/country).
class _ScopedLeaderboard extends ConsumerWidget {
  final FutureProvider<List<LeaderboardEntry>> provider;
  const _ScopedLeaderboard({required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leaderboard = ref.watch(provider);
    final user = ref.watch(userProfileProvider);

    return leaderboard.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: ShimmerBox(height: 140)),
                const SizedBox(width: 8),
                Expanded(child: ShimmerBox(height: 180)),
                const SizedBox(width: 8),
                Expanded(child: ShimmerBox(height: 120)),
              ],
            ),
            const SizedBox(height: 24),
            Expanded(child: ShimmerList(itemCount: 5, itemHeight: 56, padding: EdgeInsets.zero)),
          ],
        ),
      ),
      error: (err, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 48, color: AppColors.grey),
            const SizedBox(height: 12),
            Text('Could not load leaderboard', style: TextStyle(color: AppColors.grey)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.invalidate(provider),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (entries) => Column(
        children: [
          if (entries.length >= 3) _TopThreePodium(top3: entries.sublist(0, 3)),
          const SizedBox(height: 12),
          Expanded(child: _RankingList(
            players: entries.length > 3 ? entries.sublist(3) : (entries.length < 3 ? entries : []),
            currentUserName: user.displayName,
          )),
        ],
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// TOP 3 PODIUM
/// ─────────────────────────────────────────────────────────────────────────────

class _TopThreePodium extends StatelessWidget {
  final List<LeaderboardEntry> top3;
  const _TopThreePodium({required this.top3});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: _PodiumItem(entry: top3[1], height: 80)),
          const SizedBox(width: 8),
          Expanded(child: _PodiumItem(entry: top3[0], height: 100)),
          const SizedBox(width: 8),
          Expanded(child: _PodiumItem(entry: top3[2], height: 64)),
        ],
      ),
    );
  }
}

class _PodiumItem extends StatelessWidget {
  final LeaderboardEntry entry;
  final double height;
  const _PodiumItem({required this.entry, required this.height});

  @override
  Widget build(BuildContext context) {
    const medals = ['🥇', '🥈', '🥉'];
    return GestureDetector(
      onTap: () => context.push('/user-profile', extra: {
        'userId': entry.userId,
        'name': entry.displayName,
        'avatar': entry.avatarId,
        'color': entry.color,
        'rank': entry.rank,
      }),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(medals[entry.rank - 1], style: const TextStyle(fontSize: 24)),
          const SizedBox(height: 4),
          AvatarWidget(avatarId: entry.avatarId, color: entry.color, size: 44, hexes: entry.cellCount),
          const SizedBox(height: 4),
          Text(entry.displayName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13), overflow: TextOverflow.ellipsis, maxLines: 1),
          Text('${entry.cellCount} ⬡', style: TextStyle(fontSize: 11, color: AppColors.grey)),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            height: height,
            decoration: BoxDecoration(
              color: entry.rank == 1 ? AppColors.yellow.withValues(alpha: 0.3)
                  : entry.rank == 2 ? AppColors.grey.withValues(alpha: 0.2)
                  : AppColors.orange.withValues(alpha: 0.2),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// RANKING LIST
/// ─────────────────────────────────────────────────────────────────────────────

class _RankingList extends StatelessWidget {
  final List<LeaderboardEntry> players;
  final String currentUserName;
  const _RankingList({required this.players, required this.currentUserName});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: players.length,
      separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.greyLight),
      itemBuilder: (context, index) {
        final p = players[index];
        final isMe = p.displayName == currentUserName;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: isMe ? null : () => context.push('/user-profile', extra: {
            'userId': p.userId,
            'name': p.displayName,
            'avatar': p.avatarId,
            'color': p.color,
            'rank': p.rank,
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            decoration: BoxDecoration(
              color: isMe ? AppColors.primary.withValues(alpha: 0.08) : null,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    '#${p.rank}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: isMe ? AppColors.primary : AppColors.grey,
                    ),
                  ),
                ),
                AvatarWidget(avatarId: p.avatarId, color: p.color, size: 36, hexes: p.cellCount),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      // Tier indicator — small colored hexagon showing rank at a glance
                      // Tier follows the snapshot cellCount so the badge matches the
                      // count and rank shown in the same row (never the live User.HexCount).
                      Icon(Icons.hexagon, size: 14, color: HexTier.fromHexes(p.cellCount).color),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          p.displayName,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: isMe ? AppColors.primary : AppColors.dark,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                Text('${p.cellCount} ⬡', style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        );
      },
    );
  }
}
