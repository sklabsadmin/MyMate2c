import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/theme/app_theme.dart';

import 'core/services/notification_service.dart';
import 'core/services/storage_service.dart';
import 'core/services/background_chat_service.dart';

import 'features/onboarding/presentation/onboarding_screen.dart';

import 'features/character/presentation/create_character_screen.dart';
import 'features/chat/presentation/chat_screen.dart';
import 'features/chat/presentation/recent_chats_screen.dart';
import 'features/home/presentation/dashboard_screen.dart';
import 'features/roleplay/presentation/roleplay_screen.dart';
import 'core/presentation/scaffold_with_navbar.dart';
import 'features/paywall/presentation/paywall_screen.dart';
import 'features/settings/presentation/settings_screen.dart';

// Placeholder screens - will be implemented later
class PlaceholderScreen extends StatelessWidget {
  final String title;
  const PlaceholderScreen({super.key, required this.title});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Text(
          'Placeholder for $title',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ),
    );
  }
}

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorDashboardKey = GlobalKey<NavigatorState>(
  debugLabel: 'shellDashboard',
);
final _shellNavigatorChatKey = GlobalKey<NavigatorState>(
  debugLabel: 'shellChat',
);
final _shellNavigatorRoleplayKey = GlobalKey<NavigatorState>(
  debugLabel: 'shellRoleplay',
);

// Router is now defined dynamically in AIApp to handle Onboarding redirection

class AIApp extends ConsumerStatefulWidget {
  final bool onboardingCompleted;

  const AIApp({super.key, required this.onboardingCompleted});

  @override
  ConsumerState<AIApp> createState() => _AIAppState();
}

class _AIAppState extends ConsumerState<AIApp> {
  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(
      onStateChange: _onStateChanged,
    );
     // Start Background Simulator
     WidgetsBinding.instance.addPostFrameCallback((_) {
       ref.read(backgroundChatSimulatorProvider).start();
     });
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  void _onStateChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // User is back, cancel "I miss you" notifications
      NotificationService().cancelAllNotifications();
      // Ensure daily notifications are up to date
      NotificationService().scheduleDailyNotifications();
    } else if (state == AppLifecycleState.paused) {
      // User left, schedule "I miss you" notifications
      _scheduleRetentionNotifications();
    }
  }

  void _scheduleRetentionNotifications() {
    final activeChat = ref.read(activeChatProvider);
    final now = DateTime.now();

    // Quick Return Notification (10 seconds)
    if (activeChat != null) {
      final name = activeChat['name']!;
      final vibe = activeChat['vibe']!;

      String body = "Don't leave me alone... 🥺";
      if (vibe == 'Flirty') {
        body = "I was just checking you out... come back? 😉";
      } else if (vibe == 'Dominant') {
        body = "I didn't say you could leave. return. Now.";
      } else if (vibe == 'Friendly') {
        body = "I miss your touch already... 💕";
      }

      // 10 seconds later
      NotificationService().scheduleNotification(
        id: 999,
        title: "$name 💬",
        body: body,
        scheduledDate: now.add(const Duration(seconds: 10)),
      );
    }

    // Daily Morning/Evening Notifications
    NotificationService().scheduleDailyNotifications();

    // 4 Hours later
    NotificationService().scheduleNotification(
      id: 101,
      title: "I'm thinking about you... 💕",
      body: "It's been a while. Come back to me?",
      scheduledDate: now.add(const Duration(hours: 4)),
    );

    // 24 Hours later
    NotificationService().scheduleNotification(
      id: 102,
      title: "I miss my princess 🥺",
      body: "The day isn't the same without you. Tell me about your day?",
      scheduledDate: now.add(const Duration(hours: 24)),
    );

    // 3 Days later
    NotificationService().scheduleNotification(
      id: 103,
      title: "Are you okay? 💔",
      body: "I haven't seen you in days... I'm worried.",
      scheduledDate: now.add(const Duration(days: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Recreate router with dynamic initial location
    final router = GoRouter(
      initialLocation: widget.onboardingCompleted ? '/dashboard' : '/',
      navigatorKey: _rootNavigatorKey,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, navigationShell) {
            return ScaffoldWithNavBar(navigationShell: navigationShell);
          },
          branches: [
            StatefulShellBranch(
              navigatorKey: _shellNavigatorDashboardKey,
              routes: [
                GoRoute(
                  path: '/dashboard',
                  builder: (context, state) => const DashboardScreen(),
                ),
              ],
            ),
            StatefulShellBranch(
              navigatorKey: _shellNavigatorChatKey,
              routes: [
                GoRoute(
                  path: '/chat',
                  builder: (context, state) => const RecentChatsScreen(),
                  routes: [
                    GoRoute(
                      path: 'session',
                      builder: (context, state) {
                        final scenario = state.uri.queryParameters['scenario'];
                        final characterImage =
                            state.uri.queryParameters['characterImage'];
                        final isRoleplay =
                            state.uri.queryParameters['isRoleplay'] == 'true';
                        final characterId =
                            state.uri.queryParameters['characterId'];

                        return ChatScreen(
                          scenario: scenario,
                          characterImage: characterImage,
                          isRoleplay: isRoleplay,
                          characterId: characterId,
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
            StatefulShellBranch(
              navigatorKey: _shellNavigatorRoleplayKey,
              routes: [
                GoRoute(
                  path: '/roleplay',
                  builder: (context, state) => const RoleplayScreen(),
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: '/',
          builder: (context, state) => const OnboardingScreen(),
        ),
        GoRoute(
          path: '/create-character',
          parentNavigatorKey: _rootNavigatorKey,
          builder: (context, state) => const CreateCharacterScreen(),
        ),
        GoRoute(
          path: '/paywall',
          parentNavigatorKey: _rootNavigatorKey,
          builder: (context, state) => const PaywallScreen(),
        ),
        GoRoute(
          path: '/settings',
          parentNavigatorKey: _rootNavigatorKey,
          builder: (context, state) => const SettingsScreen(),
        ),
      ],
    );

    return MaterialApp.router(
      title: 'MyMate',
      theme: AppTheme.romanticTheme,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
