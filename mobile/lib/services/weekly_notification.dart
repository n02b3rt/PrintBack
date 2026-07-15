import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// A single weekly local notification: every Monday 09:00 local time, a
/// short footfall summary. Computed and (re)scheduled from the app on
/// launch (no background workers in v1) - the content is a snapshot of
/// what the local db knows at scheduling time, which is plenty for a
/// "here's your week" nudge (report 4). Local-only, nothing leaves the
/// phone.
class WeeklyNotification {
  WeeklyNotification._();
  static final instance = WeeklyNotification._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _weeklyId = 1001;
  static const _channelId = 'weekly_summary';

  Future<void> init() async {
    tzdata.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
    _ready = true;
  }

  /// Android 13+ requires a runtime notification permission. Returns
  /// whether notifications are allowed (true on older Android / other
  /// platforms where it's implicit).
  Future<bool> requestPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? true;
  }

  Future<void> scheduleWeekly({
    required String title,
    required String body,
  }) async {
    if (!_ready) return;
    await _plugin.cancel(_weeklyId);
    await _plugin.zonedSchedule(
      _weeklyId,
      title,
      body,
      _nextMonday9(),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Weekly summary',
          channelDescription: 'Weekly footfall summary',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
      // Inexact avoids the exact-alarm permission; a weekly 9am nudge
      // doesn't need to-the-second timing.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      // Repeat every Monday at this time.
      matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
    );
  }

  Future<void> cancel() => _plugin.cancel(_weeklyId);

  /// The next Monday at 09:00 of the device's local wall clock, expressed
  /// as the equivalent absolute UTC instant. Deriving from the local
  /// DateTime avoids a device-timezone-name lookup (and its heavyweight
  /// plugin); the weekly repeat can drift by the DST offset (up to an
  /// hour, twice a year), which is fine for a weekly nudge.
  tz.TZDateTime _nextMonday9() {
    final now = DateTime.now();
    var d = DateTime(now.year, now.month, now.day, 9);
    while (d.weekday != DateTime.monday || !d.isAfter(now)) {
      final next = d.add(const Duration(days: 1));
      d = DateTime(next.year, next.month, next.day, 9);
    }
    return tz.TZDateTime.from(d.toUtc(), tz.UTC);
  }
}
