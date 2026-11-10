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

  /// Called with a roster character id when a notification written in that
  /// character's voice is tapped while the app is running or suspended. The
  /// app sets it to open that conversation. A tap that LAUNCHES the app is
  /// reported by [launchCharacterId] instead — there is nobody to call yet.
  void Function(String characterId)? onCharacterTap;

  /// What every notification in the app's own voice is titled with, ahead of
  /// its own heading: "In Mythos World · Dawn ☀️". A character's notification
  /// is titled "Zeus says" instead (CharacterNudgePlanner), so the two kinds
  /// can be told apart at a glance on a lock screen.
  static const String appLevelPrefix = 'In Mythos World';

  /// [heading] as an app-level notification title.
  static String appLevelTitle(String heading) => '$appLevelPrefix · $heading';

  static const String _characterPayloadPrefix = 'character:';

  /// The payload that makes a tap open [characterId]'s conversation.
  static String characterPayload(String characterId) =>
      '$_characterPayloadPrefix$characterId';

  /// The character a payload names, or null for any other notification.
  static String? characterIdFrom(String? payload) {
    if (payload == null || !payload.startsWith(_characterPayloadPrefix)) {
      return null;
    }
    final id = payload.substring(_characterPayloadPrefix.length);
    return RegExp(r'^[a-z0-9_]{1,40}$').hasMatch(id) ? id : null;
  }

  /// The character whose notification opened the app from cold, if that is
  /// how this launch began.
  Future<String?> launchCharacterId() async {
    if (kIsWeb) return null;
    try {
      final details = await _flutterLocalNotificationsPlugin
          .getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) return null;
      return characterIdFrom(details.notificationResponse?.payload);
    } catch (_) {
      return null;
    }
  }

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
            final characterId = characterIdFrom(notificationResponse.payload);
            if (characterId != null) onCharacterTap?.call(characterId);
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
    String? payload,
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
      payload: payload,
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
          title: appLevelTitle("Dawn ☀️"),
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
          title: appLevelTitle("Nightfall 🌙"),
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
