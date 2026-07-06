/// In-app notification store.
///
/// Captures territory theft events from SignalR and push messages
/// so users can see a history of what happened to their territory.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:myloop/shared/services/notification_cache.dart';
import 'package:myloop/shared/services/user_state.dart';

/// A single in-app notification entry.
class AppNotification {
  final String id;
  final String title;
  final String body;
  final DateTime timestamp;
  bool isRead;

  AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.timestamp,
    this.isRead = false,
  });

  /// Pure JSON round-trip used by [NotificationCache] persistence.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'timestamp': timestamp.toIso8601String(),
        'isRead': isRead,
      };

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as String,
        title: json['title'] as String,
        body: json['body'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        isRead: json['isRead'] as bool? ?? false,
      );
}

/// Riverpod notifier that manages the persistent in-app notification list.
///
/// The inbox is file-backed via [NotificationCache] (issue #30): restored on build,
/// written after every mutation, and bound to the signed-in user id so a second account
/// on the same device never inherits the first user's notifications.
class NotificationNotifier extends Notifier<List<AppNotification>> {
  @override
  List<AppNotification> build() {
    _hydrate();
    return [];
  }

  String? get _userId => ref.read(userProfileProvider).userId;

  /// Restores the cached inbox for the current user. Skips if an alert already landed
  /// during the async load, so a just-arrived SignalR theft alert is never clobbered.
  Future<void> _hydrate() async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) return;
    final cached = await NotificationCache.load(userId);
    if (cached != null && cached.isNotEmpty && state.isEmpty) {
      state = cached;
    }
  }

  Future<void> _persist() async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) return;
    await NotificationCache.save(userId, state);
  }

  void addTheftAlert({
    required String thiefName,
    required String thiefColor,
    required int hexCount,
  }) {
    final n = AppNotification(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: 'Territory Under Attack! ⚔️',
      body: '$thiefName captured $hexCount of your hex${hexCount == 1 ? '' : 'es'}!',
      timestamp: DateTime.now(),
    );
    state = [n, ...state.take(49)]; // Keep last 50
    _persist();
  }

  void markAllRead() {
    state = state.map((n) => AppNotification(
      id: n.id,
      title: n.title,
      body: n.body,
      timestamp: n.timestamp,
      isRead: true,
    )).toList();
    _persist();
  }

  void clear() {
    state = [];
    _persist();
  }

  int get unreadCount => state.where((n) => !n.isRead).length;
}

final notificationProvider =
    NotifierProvider<NotificationNotifier, List<AppNotification>>(
  NotificationNotifier.new,
);

/// Convenience selector: number of unread notifications.
final unreadCountProvider = Provider<int>((ref) {
  final notifications = ref.watch(notificationProvider);
  return notifications.where((n) => !n.isRead).length;
});
