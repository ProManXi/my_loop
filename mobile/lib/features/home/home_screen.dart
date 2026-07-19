/// Home screen shell - main navigation container for authenticated users.
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:myloop/app/theme.dart';
import 'package:myloop/features/home/home_tab.dart';
import 'package:myloop/features/journey/journey_controller.dart';
import 'package:myloop/features/leaderboard/leaderboard_screen.dart';
import 'package:myloop/features/achievements/achievements_screen.dart';
import 'package:myloop/shared/models/player_titles.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/auth_service.dart';
import 'package:myloop/shared/services/game_state_cache.dart';
import 'package:myloop/shared/services/profile_cache.dart';
import 'package:myloop/shared/services/territory_cache.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/shared/state/profile_slice.dart';
import 'package:myloop/shared/widgets/avatar_widget.dart';

/// Global key so child widgets (like home_tab) can open the end drawer.
final homeScaffoldKey = GlobalKey<ScaffoldState>();

/// Controls FAB visibility — set to false when modals/sheets are open.
final homeFabVisible = ValueNotifier<bool>(true);

/// The app shell scaffold providing bottom navigation and the journey FAB (home only).
/// Uses IndexedStack to keep all tabs alive — eliminates the tab-switch glitch
/// where old content would show for a frame during GoRouter's child swap.
class HomeScreen extends ConsumerWidget {
  final Widget child; // kept for ShellRoute compat but ignored
  const HomeScreen({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.path;
    int currentIndex = 0;
    if (location == '/leaderboard') currentIndex = 1;
    if (location == '/achievements') currentIndex = 2;

    return Scaffold(
      key: homeScaffoldKey,
      body: IndexedStack(
        index: currentIndex,
        children: const [
          HomeTab(),
          LeaderboardScreen(),
          AchievementsScreen(),
        ],
      ),
      endDrawer: const _ProfileDrawer(),
      floatingActionButton: currentIndex == 0
        ? ValueListenableBuilder<bool>(
            valueListenable: homeFabVisible,
            builder: (_, visible, child) => visible ? child! : const SizedBox.shrink(),
            child: _StartJourneyFab(),
          )
        : const SizedBox.shrink(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButtonAnimator: _NoAnimationFabAnimator(),
      bottomNavigationBar: _BottomNav(currentIndex: currentIndex),
    );
  }
}

/// Sidebar drawer for profile settings (no stats — those stay on homepage).
class _ProfileDrawer extends ConsumerWidget {
  const _ProfileDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider);
    final hexCount = ref.watch(profileSliceProvider.select((s) => s.hexCount));
    final title = getTitleForHexes(hexCount);
    final avatarColor = Color(int.parse(profile.color.replaceFirst('#', ''), radix: 16) | 0xFF000000);

    return Drawer(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(left: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Gradient header with avatar + title
          Container(
            width: double.infinity,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 32,
              bottom: 28,
              left: 24,
              right: 24,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [avatarColor.withValues(alpha: 0.15), avatarColor.withValues(alpha: 0.05)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: avatarColor.withValues(alpha: 0.3),
                        blurRadius: 20,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: AvatarWidget(avatarId: profile.avatarId, color: profile.color, size: 80),
                ),
                const SizedBox(height: 14),
                Text(
                  profile.displayName,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                // Title badge — properly aligned emoji + text
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [avatarColor.withValues(alpha: 0.2), avatarColor.withValues(alpha: 0.08)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: avatarColor.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(title.emoji, style: const TextStyle(fontSize: 14, height: 1.0)),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          title.label,
                          style: TextStyle(
                            color: avatarColor,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            letterSpacing: 0.3,
                            height: 1.2,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Menu items
          const SizedBox(height: 8),
          _DrawerTile(
            icon: Icons.palette_outlined,
            label: 'Change Avatar & Color',
            onTap: () {
              Navigator.pop(context);
              context.push('/profile');
            },
          ),
          _DrawerTile(
            icon: Icons.edit_outlined,
            label: 'Edit Display Name',
            onTap: () {
              Navigator.pop(context);
              _showNameEditor(context, ref);
            },
          ),
          _DrawerTile(
            icon: Icons.notifications_outlined,
            label: 'Notifications',
            onTap: () {
              Navigator.pop(context);
              context.push('/notifications');
            },
          ),
          _DrawerTile(
            icon: Icons.history_outlined,
            label: 'Walk History',
            onTap: () {
              Navigator.pop(context);
              context.push('/walk-history');
            },
          ),
          _DrawerTile(
            icon: Icons.help_outline,
            label: 'How to Play',
            onTap: () => Navigator.pop(context),
          ),

          const Spacer(),

          // Version info
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'MyLoop v0.1.0',
              style: TextStyle(color: AppColors.grey, fontSize: 11),
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, indent: 24, endIndent: 24),
          _DrawerTile(
            icon: Icons.logout_outlined,
            label: 'Sign Out',
            iconColor: AppColors.red,
            onTap: () async {
              Navigator.pop(context);
              ref.read(userProfileProvider.notifier).clear();
              await ref.read(authServiceProvider).signOut();
              if (context.mounted) context.go('/login');
            },
          ),
          const SizedBox(height: 4),
          _DrawerTile(
            icon: Icons.delete_forever_outlined,
            label: 'Delete Account',
            iconColor: Colors.red.shade900,
            onTap: () => _confirmDeleteAccount(context, ref),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
        ],
      ),
    );
  }

  void _showNameEditor(BuildContext context, WidgetRef ref) {
    final profile = ref.read(userProfileProvider);
    final controller = TextEditingController(text: profile.displayName);
    String? errorText;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(left: 24, right: 24, top: 24, bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Edit Display Name', style: Theme.of(ctx).textTheme.headlineMedium),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 20,
                decoration: InputDecoration(
                  hintText: 'Enter your name',
                  errorText: errorText,
                  counterText: '',
                  filled: true,
                  fillColor: AppColors.snow,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.greyLight)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 2)),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    final name = controller.text.trim();
                    final validated = _validateDisplayName(name);
                    if (validated != null) {
                      setSheetState(() => errorText = validated);
                      return;
                    }
                    ref.read(userProfileProvider.notifier).updateDisplayName(name);
                    Navigator.pop(ctx);
                  },
                  child: const Text('SAVE'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Validates display name: 2-20 chars, alphanumeric + spaces + basic punctuation only.
  String? _validateDisplayName(String name) {
    if (name.isEmpty) return 'Name cannot be empty';
    if (name.length < 2) return 'Name must be at least 2 characters';
    if (name.length > 20) return 'Name must be 20 characters or less';
    // Allow letters, numbers, spaces, hyphens, underscores, apostrophes
    final valid = RegExp(r"^[a-zA-Z0-9 \-_']+$");
    if (!valid.hasMatch(name)) return 'Only letters, numbers, spaces, hyphens allowed';
    return null;
  }

  void _confirmDeleteAccount(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Account', style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text(
          'This will permanently delete your account, all territory, stats, and progress. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx); // close dialog
              Navigator.pop(context); // close drawer
              final profile = ref.read(userProfileProvider);
              final api = ref.read(apiServiceProvider);
              final uid = profile.userId;
              if (uid == null) return;
              await ProfileCache.clear();
              await GameStateCache.clear();
              await TerritoryCache.clear();
              try {
                await api.deleteAccount(uid);
                await FirebaseAuth.instance.currentUser?.delete();
              } catch (_) {
                // Firebase delete may fail if re-auth needed — account is already gone server-side
                await FirebaseAuth.instance.signOut();
              }
              if (context.mounted) context.go('/login');
            },
            child: Text('Delete', style: TextStyle(color: Colors.red.shade900, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;
  const _DrawerTile({required this.icon, required this.label, required this.onTap, this.iconColor});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor ?? AppColors.dark, size: 22),
      title: Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: iconColor ?? AppColors.dark)),
      trailing: const Icon(Icons.chevron_right, color: AppColors.grey, size: 20),
      onTap: onTap,
    );
  }
}

/// Disables the default FAB scale+fade animation.
class _NoAnimationFabAnimator extends FloatingActionButtonAnimator {
  @override
  Offset getOffset({required Offset begin, required Offset end, required double progress}) {
    return end;
  }

  @override
  Animation<double> getScaleAnimation({required Animation<double> parent}) {
    return const AlwaysStoppedAnimation(1.0);
  }

  @override
  Animation<double> getRotationAnimation({required Animation<double> parent}) {
    return const AlwaysStoppedAnimation(0.0);
  }
}

/// Attractive animated FAB that launches the journey screen.
/// Includes a delayed fade-in to sync with the home tab shimmer loading.
class _StartJourneyFab extends StatefulWidget {
  @override
  State<_StartJourneyFab> createState() => _StartJourneyFabState();
}

class _StartJourneyFabState extends State<_StartJourneyFab> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    // Delay start to match shimmer duration (600ms)
    Future.delayed(const Duration(milliseconds: 650), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slide,
      child: FadeTransition(
        opacity: _opacity,
        child: _JourneyButton(),
      ),
    );
  }
}

/// The actual journey button visual.
class _JourneyButton extends ConsumerStatefulWidget {
  @override
  ConsumerState<_JourneyButton> createState() => _JourneyButtonState();
}

class _JourneyButtonState extends ConsumerState<_JourneyButton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$m:$s';
    }
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final journey = ref.watch(journeyControllerProvider);
    final isActive = journey.status == JourneyStatus.tracking;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.push('/journey'),
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            final pulse = _isHovered
                ? 1.12 + (_pulseController.value * 0.03)
                : 1.0 + (_pulseController.value * 0.04);
            final glowOpacity = _isHovered
                ? 0.6 + (_pulseController.value * 0.3)
                : 0.3 + (_pulseController.value * 0.3);
            final blurRadius = _isHovered ? 32.0 : 20.0;
            final spreadRadius = _isHovered ? 6.0 : 2.0;

            // Active journey: red/crimson gradient with stronger pulse
            final gradientColors = isActive
                ? (_isHovered
                    ? [const Color(0xFFFF4444), const Color(0xFFCC0000)]
                    : [const Color(0xFFE53935), const Color(0xFFB71C1C)])
                : (_isHovered
                    ? [const Color(0xFF00E4BB), AppColors.primary]
                    : [AppColors.primary, AppColors.primaryDark]);

            final shadowColor = isActive
                ? const Color(0xFFE53935)
                : AppColors.primary;

            return AnimatedScale(
              scale: pulse,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: Container(
                height: 60,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  gradient: LinearGradient(
                    colors: gradientColors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: shadowColor.withValues(alpha: glowOpacity),
                      offset: const Offset(0, 4),
                      blurRadius: blurRadius,
                      spreadRadius: spreadRadius,
                    ),
                    if (_isHovered || isActive)
                      BoxShadow(
                        color: shadowColor.withValues(alpha: 0.2),
                        offset: const Offset(0, 0),
                        blurRadius: 40,
                        spreadRadius: 10,
                      ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icon: running indicator or hexagon
                    Transform.rotate(
                      angle: isActive
                          ? _pulseController.value * 0.3
                          : (_isHovered
                              ? _pulseController.value * 0.5
                              : _pulseController.value * 0.1),
                      child: Icon(
                        isActive ? Icons.directions_run : Icons.hexagon,
                        color: AppColors.white,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Text: timer or "Start Journey"
                    isActive
                        ? Text(
                            _formatDuration(journey.elapsed),
                            style: const TextStyle(
                              color: AppColors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              fontFeatures: [FontFeature.tabularFigures()],
                              letterSpacing: 1.0,
                            ),
                          )
                        : const Text(
                            'Start Journey',
                            style: TextStyle(
                              color: AppColors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                    const SizedBox(width: 6),
                    Icon(
                      isActive ? Icons.timer : Icons.arrow_forward_rounded,
                      color: Colors.white.withValues(alpha: 0.8),
                      size: 20,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Bottom navigation bar: Home, Ranks, Achievements.
class _BottomNav extends ConsumerWidget {
  final int currentIndex;
  const _BottomNav({required this.currentIndex});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider);

    return BottomNavigationBar(
      currentIndex: currentIndex,
      onTap: (index) {
        switch (index) {
          case 0:
            context.go('/home');
          case 1:
            context.go('/leaderboard');
          case 2:
            context.go('/achievements');
          case 3:
            // Open side drawer instead of navigating
            homeScaffoldKey.currentState?.openEndDrawer();
        }
      },
      items: [
        const BottomNavigationBarItem(
          icon: Icon(Icons.home_outlined, size: 24),
          activeIcon: Icon(Icons.home, size: 28),
          label: 'Home',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.leaderboard_outlined, size: 24),
          activeIcon: Icon(Icons.leaderboard, size: 28),
          label: 'Ranks',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.emoji_events_outlined, size: 24),
          activeIcon: Icon(Icons.emoji_events, size: 28),
          label: 'Achievements',
        ),
        BottomNavigationBarItem(
          icon: AvatarWidget(avatarId: profile.avatarId, color: profile.color, size: 34),
          activeIcon: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.primary, width: 2),
            ),
            child: AvatarWidget(avatarId: profile.avatarId, color: profile.color, size: 36),
          ),
          label: '',
        ),
      ],
    );
  }
}