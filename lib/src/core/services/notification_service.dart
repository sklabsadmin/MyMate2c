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
  }

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
          'your_channel_id',
          'your_channel_name',
          channelDescription: 'your_channel_description',
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

    await _flutterLocalNotificationsPlugin.zonedSchedule(
      id: id,
      scheduledDate: tz.TZDateTime.from(scheduledDate, tz.local),
      notificationDetails: const fln.NotificationDetails(
        android: fln.AndroidNotificationDetails(
          'your_channel_id',
          'your_channel_name',
          channelDescription: 'your_channel_description',
        ),
        iOS: fln.DarwinNotificationDetails(),
      ),
      androidScheduleMode: fln.AndroidScheduleMode.exactAllowWhileIdle,
      title: title,
      body: body,
      payload: null,
    );
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
