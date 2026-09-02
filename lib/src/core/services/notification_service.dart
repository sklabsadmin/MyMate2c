import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() {
    return _instance;
  }

  NotificationService._internal();

  // Morning messages (9 AM)
  // Shared by every character, so these stay mythic in flavour rather than
  // in any one voice. Deliberately not romantic: the app is a companion and
  // mentor, and the previous set ("morning kisses", "hey handsome") predated
  // that framing.
  final List<String> _morningMessages = [
    "Rosy-fingered dawn. Homer's phrase, not mine — but he had a point.",
    "The sun's chariot is up. You have the whole day ahead of you.",
    "Morning. What does today ask of you?",
    "A new voyage every morning. Where are you headed?",
    "The Fates spin, but the day is still yours to shape.",
    "Even Olympus stirs slowly at this hour. ☕",
    "New day. Nothing decided yet.",
  ];

  // Evening messages (8 PM)
  final List<String> _eveningMessages = [
    "The lamps are lit. How did the day treat you?",
    "Even Odysseus made camp at nightfall.",
    "Set the day down. It will keep until morning.",
    "The stars are out — the same ones the sailors steered by. 🌙",
    "Rest is not surrender. Ask any soldier.",
    "The hearth is warm whenever you want it.",
    "Nightfall. Tell me what the day held.",
  ];

  final fln.FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      fln.FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    if (kIsWeb) {
      return;
    }

    tz.initializeTimeZones();

    const fln.AndroidInitializationSettings initializationSettingsAndroid =
        fln.AndroidInitializationSettings('@mipmap/ic_launcher');

    final fln.DarwinInitializationSettings initializationSettingsDarwin =
        fln.DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        );

    final fln.InitializationSettings initializationSettings =
        fln.InitializationSettings(
          android: initializationSettingsAndroid,
          iOS: initializationSettingsDarwin,
          macOS: initializationSettingsDarwin,
        );

    await _flutterLocalNotificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse:
          (fln.NotificationResponse notificationResponse) async {
            // Handle notification tap
          },
    );

    await _prepareAndroid();
  }

  /// Whether Android will let us fire a reminder at an exact minute.
  ///
  /// Android 12 granted SCHEDULE_EXACT_ALARM to anyone who declared it;
  /// Android 13+ denies it by default and offers the user a toggle in the
  /// app's settings. Asking for it here is not worth the friction, so the
  /// service just checks, and falls back to an inexact alarm (delivered within
  /// a window rather than on the dot). Reminders at "9am-ish" are fine; the
  /// only one that notices is the 10-second "you left mid-thought" nudge.
  bool _canScheduleExact = false;

  Future<void> _prepareAndroid() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final android = _flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            fln.AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;

    // Android 13+: notifications are a runtime permission. Without this
    // prompt every scheduled reminder is dropped without a trace. iOS asks
    // through the DarwinInitializationSettings flags above; this is the
    // Android equivalent. Older versions return true without prompting.
    try {
      await android.requestNotificationsPermission();
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }

    try {
      _canScheduleExact = await android.canScheduleExactNotifications() ?? false;
    } catch (e) {
      debugPrint('canScheduleExactNotifications failed: $e');
      _canScheduleExact = false;
    }
  }

  // One channel for everything the app sends. Channel ids are permanent once
  // a user has seen them (Android keeps the user's per-channel settings), so
  // this name is the one to keep.
  static const String _channelId = 'mythos_reminders';
  static const String _channelName = 'Reminders';
  static const String _channelDescription =
      'Morning and evening messages, and a nudge when a story is left unfinished.';

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    if (kIsWeb) {
      return;
    }

    const fln.AndroidNotificationDetails androidNotificationDetails =
        fln.AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: fln.Importance.max,
          priority: fln.Priority.high,
        );

    const fln.NotificationDetails notificationDetails = fln.NotificationDetails(
      android: androidNotificationDetails,
      iOS: fln.DarwinNotificationDetails(),
    );

    await _flutterLocalNotificationsPlugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: notificationDetails,
      payload: null,
    );
  }

  Future<void> scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) async {
    if (kIsWeb) {
      return;
    }

    // exactAllowWhileIdle throws PlatformException(exact_alarms_not_permitted)
    // on Android 13+ unless the user has flipped the toggle, and app.dart
    // calls this without awaiting, so that exception used to surface as an
    // uncaught zone error and the reminder was never set. Pick the mode the
    // device actually allows, and treat a scheduling failure as "no reminder"
    // rather than a crash: a missed nudge is not worth breaking the app over.
    try {
      await _flutterLocalNotificationsPlugin.zonedSchedule(
        id: id,
        scheduledDate: tz.TZDateTime.from(scheduledDate, tz.local),
        notificationDetails: const fln.NotificationDetails(
          android: fln.AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
          ),
          iOS: fln.DarwinNotificationDetails(),
        ),
        androidScheduleMode: _canScheduleExact
            ? fln.AndroidScheduleMode.exactAllowWhileIdle
            : fln.AndroidScheduleMode.inexactAllowWhileIdle,
        title: title,
        body: body,
        payload: null,
      );
    } catch (e) {
      debugPrint('Could not schedule notification $id: $e');
    }
  }

  Future<void> scheduleDailyNotifications() async {
    if (kIsWeb) {
      return;
    }

    final now = DateTime.now();

    // Schedule for the next 7 days
    for (int i = 0; i < 7; i++) {
      final dayOffset = now.add(Duration(days: i));

      // Morning Notification (9:00 AM)
      final morningDate = DateTime(
        dayOffset.year,
        dayOffset.month,
        dayOffset.day,
        9,
        0,
      );
      if (morningDate.isAfter(now)) {
        final msgIndex =
            (now.day + i) % _morningMessages.length; // Rotate messages
        await scheduleNotification(
          id: 200 + i,
          title: "Dawn ☀️",
          body: _morningMessages[msgIndex],
          scheduledDate: morningDate,
        );
      }

      // Evening Notification (8:00 PM)
      final eveningDate = DateTime(
        dayOffset.year,
        dayOffset.month,
        dayOffset.day,
        20,
        0,
      );
      if (eveningDate.isAfter(now)) {
        final msgIndex =
            (now.day + i) % _eveningMessages.length; // Rotate messages
        await scheduleNotification(
          id: 300 + i,
          title: "Nightfall 🌙",
          body: _eveningMessages[msgIndex],
          scheduledDate: eveningDate,
        );
      }
    }
  }

  Future<void> cancelAllNotifications() async {
    if (kIsWeb) {
      return;
    }

    await _flutterLocalNotificationsPlugin.cancelAll();
  }
}
