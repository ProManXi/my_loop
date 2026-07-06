/// Local cache of the signed-in user's in-app notification inbox.
///
/// The inbox (theft alerts, game events) was a plain in-memory Riverpod list, so every
/// alert vanished on app restart (issue #30). This file-backs it, mirroring the
/// [GameStateCache] / [ProfileCache] offline pattern (issues #34 / #19): written after
/// every mutation, restored on launch, and cleared on sign-out.
///
/// The cache is bound to the server [userId] it was written for. Restore verifies that
/// binding against the user currently signed in — otherwise a second account on the same
/// device could inherit the first user's notifications (same cross-user guard as #19).
library;

import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:myloop/shared/services/notification_service.dart';
import 'package:path_provider/path_provider.dart';

final _log = Logger('NotificationCache');

/// File-backed store for the last-known notification inbox, bound to a user id. All
/// methods are static — there is no per-instance state, just JSON in the app documents
/// directory.
class NotificationCache {
  NotificationCache._();

  static const _fileName = 'notifications_cache.json';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Serializes the inbox to its JSON string form. Pure — unit-testable without the
  /// filesystem.
  static String encode(String userId, List<AppNotification> notifications) => jsonEncode({
        'userId': userId,
        'notifications': notifications.map((n) => n.toJson()).toList(),
      });

  /// Rebuilds `(userId, notifications)` from the JSON string form, or `null` if the
  /// payload has no user id or cannot be parsed. Pure — unit-testable.
  static ({String userId, List<AppNotification> notifications})? decode(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final userId = json['userId'] as String?;
      if (userId == null || userId.isEmpty) return null;
      final list = (json['notifications'] as List? ?? const [])
          .map((n) => AppNotification.fromJson(n as Map<String, dynamic>))
          .toList();
      return (userId: userId, notifications: list);
    } catch (e) {
      _log.warning('Failed to decode notification cache', e);
      return null;
    }
  }

  /// Persists [notifications] bound to [userId]. An empty [userId] is never cached —
  /// there would be no user to safely bind the payload to.
  static Future<void> save(String userId, List<AppNotification> notifications) async {
    if (userId.isEmpty) return;
    try {
      final file = await _file();
      await file.writeAsString(encode(userId, notifications), flush: true);
    } catch (e, s) {
      _log.warning('Failed to write notification cache', e, s);
    }
  }

  /// Loads the cached inbox for [userId], or `null` if none exists, it is unreadable, or
  /// it belongs to a different user (cross-user guard).
  static Future<List<AppNotification>?> load(String userId) async {
    if (userId.isEmpty) return null;
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final decoded = decode(await file.readAsString());
      if (decoded == null || decoded.userId != userId) return null;
      return decoded.notifications;
    } catch (e, s) {
      _log.warning('Failed to read notification cache', e, s);
      return null;
    }
  }

  /// Removes the cached inbox. Called on sign-out / account deletion so the next user
  /// does not inherit the previous user's notifications.
  static Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (e, s) {
      _log.warning('Failed to clear notification cache', e, s);
    }
  }
}
