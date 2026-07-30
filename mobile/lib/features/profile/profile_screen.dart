/// Profile screen - displays player identity, stats, and settings.
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:myloop/app/theme.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/auth_service.dart';
import 'package:myloop/shared/services/game_state_cache.dart';
import 'package:myloop/shared/services/profile_cache.dart';
import 'package:myloop/shared/services/step_claim_queue.dart';
import 'package:myloop/shared/services/territory_cache.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/shared/widgets/avatar_widget.dart';
import 'package:myloop/shared/widgets/color_picker_row.dart';
import 'package:myloop/shared/widgets/hex_trophy.dart';

/// The player's profile screen with identity, stats, and settings.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.dark,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 16),
              AvatarWidget(avatarId: profile.avatarId, color: profile.color, size: 80),
              const SizedBox(height: 12),
              Text(profile.displayName, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 6),
              // Tier label
              Text(
                HexTier.fullLabel(profile.hexCount),
                style: TextStyle(
                  color: HexTier.fromHexes(profile.hexCount).color,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),

              // Walk History
              _SettingsTile(
                icon: Icons.history_outlined,
                label: 'Walk History',
                onTap: () => context.push('/walk-history'),
              ),

              const SizedBox(height: 8),

              // Settings section
              _SettingsTile(
                icon: Icons.palette_outlined,
                label: 'Change Avatar & Color',
                onTap: () => _showAvatarColorPicker(context, ref),
              ),
              _SettingsTile(
                icon: Icons.edit_outlined,
                label: 'Edit Display Name',
                onTap: () => _showNameEditor(context, ref),
              ),
              _SettingsTile(
                icon: Icons.notifications_outlined,
                label: 'Notifications',
                onTap: () => context.push('/notifications'),
              ),

              const SizedBox(height: 24),

              // Sign out
              _SettingsTile(
                icon: Icons.logout_outlined,
                label: 'Sign Out',
                iconColor: AppColors.red,
                onTap: () async {
                  final uid = ref.read(userProfileProvider).userId;
                  ref.read(userProfileProvider.notifier).clear();
                  await ref.read(authServiceProvider).signOut(uid);
                  if (context.mounted) context.go('/login');
                },
              ),
              _SettingsTile(
                icon: Icons.delete_forever_outlined,
                label: 'Delete Account',
                iconColor: Colors.red.shade900,
                onTap: () => _confirmDeleteAccount(context, ref),
              ),

              SizedBox(height: MediaQuery.of(context).padding.bottom + 24),
            ],
          ),
        ),
      ),
    );
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final profile = ref.read(userProfileProvider);
              final api = ref.read(apiServiceProvider);
              final uid = profile.userId;
              if (uid == null) return;
              await ProfileCache.clear();
              await GameStateCache.clear();
              await TerritoryCache.clear();
              final queue = StepClaimQueue();
              await queue.init(uid);
              await queue.clear();
              try {
                await api.deleteAccount(uid);
                await FirebaseAuth.instance.currentUser?.delete();
              } catch (_) {
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

  void _showAvatarColorPicker(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => _AvatarColorEditor(ref: ref),
    );
  }

  void _showNameEditor(BuildContext context, WidgetRef ref) {
    final profile = ref.read(userProfileProvider);
    final controller = TextEditingController(text: profile.displayName);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
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
              decoration: InputDecoration(
                hintText: 'Enter your name',
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
                  if (name.isNotEmpty) {
                    ref.read(userProfileProvider.notifier).updateDisplayName(name);
                  }
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Name updated!'), backgroundColor: AppColors.primary),
                  );
                },
                child: const Text('SAVE'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarColorEditor extends StatefulWidget {
  final WidgetRef ref;
  const _AvatarColorEditor({required this.ref});

  @override
  State<_AvatarColorEditor> createState() => _AvatarColorEditorState();
}

class _AvatarColorEditorState extends State<_AvatarColorEditor> {
  late int _selectedAvatar;
  late int _selectedColor;

  @override
  void initState() {
    super.initState();
    final profile = widget.ref.read(userProfileProvider);
    _selectedAvatar = profile.avatarId;
    final idx = playerColors.indexOf(profile.color);
    _selectedColor = idx >= 0 ? idx : 0;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Change Avatar & Color', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 20),
          Center(child: AvatarWidget(avatarId: _selectedAvatar, color: playerColors[_selectedColor], size: 72)),
          const SizedBox(height: 20),
          SizedBox(
            height: 140,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 6, mainAxisSpacing: 8, crossAxisSpacing: 8),
              itemCount: avatarEmojis.length,
              itemBuilder: (context, index) {
                final isSelected = _selectedAvatar == index;
                return GestureDetector(
                  onTap: () => setState(() => _selectedAvatar = index),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected ? AppColors.primary.withValues(alpha: 0.15) : AppColors.snow,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isSelected ? AppColors.primary : AppColors.greyLight, width: isSelected ? 2 : 1),
                    ),
                    child: Center(child: Text(avatarEmojis[index], style: const TextStyle(fontSize: 22))),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          ColorPickerRow(
            selectedIndex: _selectedColor,
            onColorSelected: (index) => setState(() => _selectedColor = index),
            circleSize: 34,
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                widget.ref.read(userProfileProvider.notifier).updateAvatarAndColor(_selectedAvatar, playerColors[_selectedColor]);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Avatar updated!'), backgroundColor: AppColors.primary),
                );
              },
              child: const Text('SAVE CHANGES'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;
  const _SettingsTile({required this.icon, required this.label, required this.onTap, this.iconColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.greyLight, width: 2),
      ),
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          leading: Icon(icon, color: iconColor ?? AppColors.dark),
          title: Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: iconColor ?? AppColors.dark)),
          trailing: const Icon(Icons.chevron_right, color: AppColors.grey),
          onTap: onTap,
        ),
      ),
    );
  }
}