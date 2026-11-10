import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/theme/app_theme.dart';

import 'core/services/notification_service.dart';
import 'core/services/storage_service.dart';
import 'core/data/characters.dart';
import 'features/auth/presentation/signed_out_screen.dart';


import 'features/chat/presentation/chat_screen.dart';
import 'features/chat/presentation/recent_chats_screen.dart';
import 'features/home/presentation/dashboard_screen.dart';
import 'features/profile/presentation/user_profile_screen.dart';
import 'core/presentation/scaffold_with_navbar.dart';
import 'features/maintenance/presentation/maintenance_screen.dart';
import 'features/wallet/presentation/coin_store_screen.dart';
import 'features/settings/presentation/settings_screen.dart';
import 'core/config/app_config.dart';

/// Shown for any route the router doesn't recognise. Redirects to the
/// dashboard on the first frame so a bad link lands somewhere useful instead
/// of on an error page.
class _RouteNotFoundRedirect extends StatefulWidget {
  const _RouteNotFoundRedirect();

  @override
  State<_RouteNotFoundRedirect> createState() => _RouteNotFoundRedirectState();
}

class _RouteNotFoundRedirectState extends State<_RouteNotFoundRedirect> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go('/dashboard');
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: CircularProgressIndicator(color: Colors.pinkAccent)),
    );
  }
}

/// Whether [path] is an open conversation: a chat session or a /c/<id>
/// character link. '/chat' alone is the recent-chats list, not a
/// conversation.
bool isConversationPath(String path) =>
    path.startsWith('/chat/session') || path.startsWith('/c/');

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
final _shellNavigatorProfileKey = GlobalKey<NavigatorState>(
  debugLabel: 'shellProfile',
);

// Router is now defined dynamically in AIApp to handle Onboarding redirection

class AIApp extends ConsumerStatefulWidget {
  const AIApp({super.key});

  @override
  ConsumerState<AIApp> createState() => _AIAppState();
}

class _AIAppState extends ConsumerState<AIApp> {
  late final AppLifecycleListener _listener;
  // The router build() made, kept so the lifecycle hook can ask where the
  // user was when they left the app.
  GoRouter? _router;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(
      onStateChange: _onStateChanged,
    );
    // There used to be a "background chat simulator" started here: every 45s
    // (labelled "short for demo") it wrote a canned line from a random recent
    // character into that chat's history and bumped its unread count. Those
    // lines were then sent to the model as the character's own turns. Removed
    // for build 100; StorageService drops the ones already on disk.
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

    // Quick return notification: only when they left the app from inside a
    // conversation, and an hour later. It used to fire 10 seconds after ANY
    // app switch — activeChat is set when a chat opens and never cleared, so
    // leaving from the dashboard, or glancing at a text, also got
    // "You left mid-thought" from whoever they last talked to.
    final path = _router?.routerDelegate.currentConfiguration.uri.path ?? '';
    if (activeChat != null && isConversationPath(path)) {
      final name = activeChat['name']!;
      final vibe = activeChat['vibe']!;

      String body = "You left mid-thought. The story isn't finished.";
      if (vibe == 'Flirty') {
        body = "You slipped away like Odysseus from a harbour.";
      } else if (vibe == 'Friendly') {
        body = "Come back when you can — I want to hear the rest.";
      }

      NotificationService().scheduleNotification(
        id: 999,
        title: "$name 💬",
        body: body,
        scheduledDate: now.add(const Duration(hours: 1)),
      );
    }

    // Daily Morning/Evening Notifications
    NotificationService().scheduleDailyNotifications();

    // 4 Hours later
    NotificationService().scheduleNotification(
      id: 101,
      title: "The day moves on",
      body: "Something in it reminded me of what you said.",
      scheduledDate: now.add(const Duration(hours: 4)),
    );

    // 24 Hours later
    NotificationService().scheduleNotification(
      id: 102,
      title: "A day has passed",
      body: "Tell me what I missed.",
      scheduledDate: now.add(const Duration(hours: 24)),
    );

    // 3 Days later
    NotificationService().scheduleNotification(
      id: 103,
      title: "Still here",
      body: "Odysseus took ten years to get home. Take the time you need.",
      scheduledDate: now.add(const Duration(days: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Recreate router with dynamic initial location
    final router = GoRouter(
      // The holding page comes before everything, including onboarding, so
      // the first thing a visitor sees while the gate is on is the notice
      // rather than a work-in-progress build.
      // Onboarding was a single tap-through with no setup behind it, so there
      // is no first-run path any more: everyone starts on the dashboard.
      initialLocation: AppConfig.showMaintenanceGate ? '/wip' : '/dashboard',
      navigatorKey: _rootNavigatorKey,
      // With real path URLs, an unknown path (a mistyped campaign link like
      // /c/zeuss) reaches the router instead of being ignored as a hash
      // fragment. Send those to the dashboard rather than showing GoRouter's
      // raw error screen to someone arriving from a social post.
      errorBuilder: (context, state) => const _RouteNotFoundRedirect(),
      // Deep links (and reloads on a sub-route) would otherwise skip the
      // gate entirely, so bounce them back to it until it has been passed.
      redirect: (context, state) {
        if (!AppConfig.showMaintenanceGate) return null;
        if (AppConfig.maintenanceGateBypassed) return null;
        if (state.uri.path == '/wip') return null;
        // Everything is gated, campaign links included: while the holding page
        // is up it is the first thing every visitor sees. Remember where they
        // were going so passing the gate resumes that journey rather than
        // dumping them on the dashboard.
        AppConfig.gatedDestination = state.uri.toString();
        return '/wip';
      },
      routes: [
        GoRoute(
          path: '/wip',
          parentNavigatorKey: _rootNavigatorKey,
          builder: (context, state) => const MaintenanceScreen(),
        ),
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
                // Listed first so it is the branch's default location: the
                // Chat tab navigates here when tapped. A parameterized route
                // cannot be a branch default — go_router asserts on it.
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
                          initialMessage:
                              state.uri.queryParameters['initialMessage'],
                        );
                      },
                    ),
                  ],
                ),
                // Campaign deep link: /c/zeus drops straight into that
                // character's chat. Lives in the chat branch so the visitor
                // still gets the nav bar, and the URL stays /c/zeus rather
                // than being rewritten to the long /chat/session query form —
                // it has to survive being pasted into an Instagram post.
                //
                // The scenario string is built exactly as the dashboard builds
                // it, because scenario doubles as the chat id: any other
                // format would give deep-linked visitors a separate history
                // from the same character opened via a card.
                GoRoute(
                  path: '/c/:characterId',
                  builder: (context, state) {
                    // Leading id characters only. A share link pasted onto the
                    // line above another URL arrives as /c/hector%0ahttps:,
                    // which read literally matches no character and lands the
                    // visitor on the dashboard instead of the chat they were
                    // sent to. The worker recovers the same id for the Open
                    // Graph tags — extractCharacterId() in worker.js.
                    final raw = state.pathParameters['characterId']
                        ?.trim()
                        .toLowerCase();
                    final id = raw == null
                        ? null
                        : RegExp(r'^[a-z0-9_-]+').stringMatch(raw);
                    final character = characterById(id);
                    // Unknown id (typo'd or retired character): send them to
                    // the dashboard rather than an error screen.
                    if (character == null) return const _RouteNotFoundRedirect();
                    return ChatScreen(
                      scenario:
                          '${character['name']} (${character['vibe']})',
                      characterImage: character['image'] as String?,
                      isRoleplay: false,
                      characterId: character['id'] as String?,
                      // Carried so the profile cards' starter questions still
                      // send their opening line now that they route through
                      // here rather than /chat/session.
                      initialMessage:
                          state.uri.queryParameters['initialMessage'],
                    );
                  },
                ),
              ],
            ),
            // Third nav slot. Was the Roleplay/Fantasy tab, which this replaces
            // outright. roleplay_screen.dart itself was deleted in the 1.0.6
            // App Review cleanup — its scenario copy predated the friend/mentor
            // rewrite and could not ship under Extended Review. Restoring the
            // tab means rewriting that screen, not just re-adding a route.
            StatefulShellBranch(
              navigatorKey: _shellNavigatorProfileKey,
              routes: [
                GoRoute(
                  path: '/my-profile',
                  builder: (context, state) => const UserProfileScreen(),
                ),
              ],
            ),
          ],
        ),
        // Kept as a redirect rather than deleted: '/' is what people type, and
        // it is still the app's canonical entry point. OnboardingScreen itself
        // is left in the tree (unreferenced) so restoring it is one route.
        GoRoute(
          path: '/',
          redirect: (context, state) => '/dashboard',
        ),
        // Outside the shell on purpose: no bottom nav, so sign-out lands on a
        // page you have to leave deliberately.
        GoRoute(
          path: '/signed-out',
          parentNavigatorKey: _rootNavigatorKey,
          builder: (context, state) => const SignedOutScreen(),
        ),
        // /create-character is gone: the creation screen was deleted in the
        // 1.0.6 App Review cleanup (the roster is authored, not user-made).
        // An old link lands on the not-found redirect like any unknown path.
        // The coin store. Kept at /paywall as well because older call sites
        // (all behind isFreeTier, so unreachable today) still push that path.
        GoRoute(
          path: '/coins',
          parentNavigatorKey: _rootNavigatorKey,
          // extra: an optional "why you're here" line (a String), passed by
          // a tribute the player could not afford.
          builder: (context, state) => CoinStoreScreen(
            reason: state.extra is String ? state.extra as String : null,
          ),
        ),
        GoRoute(
          path: '/paywall',
          parentNavigatorKey: _rootNavigatorKey,
          builder: (context, state) => const CoinStoreScreen(),
        ),
        GoRoute(
          path: '/settings',
          parentNavigatorKey: _rootNavigatorKey,
          builder: (context, state) => const SettingsScreen(),
        ),
      ],
    );

    _router = router;
    return MaterialApp.router(
      title: 'Mythos Live',
      theme: AppTheme.romanticTheme,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
