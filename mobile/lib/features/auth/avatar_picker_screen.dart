/// Avatar picker screen — post-signup player customization.
///
/// Allows new users to choose a display name, select an avatar emoji,
/// and pick a player color before entering the main app. This data is
/// sent to the backend to create their player profile.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:myloop/app/theme.dart';
import 'package:myloop/shared/services/api_service.dart';
import 'package:myloop/shared/services/auth_service.dart';
import 'package:myloop/shared/services/user_state.dart';
import 'package:myloop/shared/state/profile_slice.dart';
import 'package:myloop/shared/widgets/avatar_widget.dart';
import 'package:myloop/shared/widgets/big_button.dart';
import 'package:myloop/shared/widgets/color_picker_row.dart';

/// Screen where new players create their in-game identity.
///
/// Presents a name input, an emoji avatar grid, a color picker row, and
/// a live preview of the combined avatar. On completion, registers the
/// user via the API and navigates to the home screen.
class AvatarPickerScreen extends ConsumerStatefulWidget {
  final String? prefillName;
  const AvatarPickerScreen({super.key, this.prefillName});

  @override
  ConsumerState<AvatarPickerScreen> createState() => _AvatarPickerScreenState();
}

/// State for [AvatarPickerScreen] managing avatar, color, and name selection.
class _AvatarPickerScreenState extends ConsumerState<AvatarPickerScreen> {
  int _selectedAvatar = 0;
  int _selectedColor = 0;
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.prefillName ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Builds the scrollable form layout with name, avatar grid, colors, and CTA.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 32),

                    // Title
                    Text(
                      'Create your player! 🎮',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 32),

                    // Name input
                    TextField(
                      controller: _nameController,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Your display name',
                        prefixIcon: const Icon(Icons.person),
                        filled: true,
                        fillColor: AppColors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(color: AppColors.greyLight),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(color: AppColors.greyLight, width: 2),
                        ),
                        focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: AppColors.primary, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Avatar label
              Text(
                'Pick your character',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),

              // Avatar grid
              SizedBox(
                height: 180,
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: avatarEmojis.length,
                  itemBuilder: (context, index) {
                    final isSelected = _selectedAvatar == index;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedAvatar = index),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.primary.withValues(alpha: 0.15)
                              : AppColors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? AppColors.primary : AppColors.greyLight,
                            width: isSelected ? 3 : 2,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            avatarEmojis[index],
                            style: const TextStyle(fontSize: 28),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),

              // Color label
              Text(
                'Pick your color',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),

              // Color picker row
              ColorPickerRow(
                selectedIndex: _selectedColor,
                onColorSelected: (index) => setState(() => _selectedColor = index),
              ),
              const SizedBox(height: 24),

              // Preview
              Center(
                child: AvatarWidget(
                  avatarId: _selectedAvatar,
                  color: playerColors[_selectedColor],
                  size: 64,
                ),
              ),

              const SizedBox(height: 32),

              // Continue button
              BigButton(
                label: "LET'S GO! 🚀",
                onPressed: _nameController.text.trim().isEmpty
                    ? () {}
                    : () => _registerAndContinue(),
              ),
              const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _registerAndContinue() async {
    final name = _nameController.text.trim();
    final color = playerColors[_selectedColor];
    final authService = ref.read(authServiceProvider);
    final api = ref.read(apiServiceProvider);

    // Determine auth provider and UID
    final firebaseUser = authService.currentUser;
    final String firebaseUid;
    final String authProvider;
    if (firebaseUser != null) {
      firebaseUid = firebaseUser.uid;
      // Determine provider from Firebase providers
      final providerData = firebaseUser.providerData;
      if (providerData.any((p) => p.providerId == 'apple.com')) {
        authProvider = 'apple';
      } else {
        authProvider = 'google';
      }
    } else {
      // Local account — let the server generate a unique UID
      firebaseUid = 'local_${name.toLowerCase().replaceAll(' ', '_')}';
      authProvider = 'local';
    }

    try {
      final user = await api.register(
        firebaseUid: firebaseUid,
        displayName: name,
        color: color,
        avatarId: _selectedAvatar,
        authProvider: authProvider,
      );

      ref.read(userProfileProvider.notifier).setFromApi(
        userId: user.id,
        avatarId: user.avatarId,
        color: user.color,
        displayName: user.displayName,
      );
      ref.read(profileSliceProvider.notifier).applyStats(
            hexCount: user.hexCount,
            streak: user.streak,
            distanceKm: user.distanceKm,
          );

      if (mounted) context.go('/set-home');
    } catch (e) {
      // If registration failed, try to look up existing user by UID
      // (handles race conditions and re-registration)
      try {
        final existing = await api.getUserByUid(firebaseUid);
        if (existing != null) {
          ref.read(userProfileProvider.notifier).setFromApi(
            userId: existing.id,
            avatarId: existing.avatarId,
            color: existing.color,
            displayName: existing.displayName,
          );
          ref.read(profileSliceProvider.notifier).applyStats(
                hexCount: existing.hexCount,
                streak: existing.streak,
                distanceKm: existing.distanceKm,
              );
          if (mounted) context.go('/home');
          return;
        }
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Registration failed: $e'), backgroundColor: AppColors.red),
        );
      }
    }
  }
}
