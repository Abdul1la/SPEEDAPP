import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 13+ needs the user to allow notifications before the background
/// GPS service can show its "warnings are on" notification. Without it the
/// warnings still work, but the driver can't see that they are on, and
/// Android is more likely to stop the app on long drives.
abstract final class NotificationPermission {
  static const _channel = MethodChannel('speed_alert/notifications');

  /// Shows the system prompt once if needed (Android only; a no-op elsewhere).
  static Future<void> request() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<bool>('request');
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }
  }
}
