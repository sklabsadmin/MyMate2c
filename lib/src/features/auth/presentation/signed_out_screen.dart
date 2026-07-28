import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';

/// Where sign-out lands, instead of dropping straight back into Settings.
///
/// Signing out used to bounce back to /settings, which looked identical to the
/// screen you had just been on — nothing confirmed that anything happened. This
/// is a deliberate dead end: it sits here until you choose to sign back in or
/// to carry on signed out, so the sign-out is unmistakably complete.
///
/// Deliberately outside the nav shell — no bottom bar — so it cannot be
/// wandered away from by accident.
class SignedOutScreen extends StatelessWidget {
  const SignedOutScreen({super.key});

  Future<void> _signInAgain() async {
    // Come back to the dashboard rather than here: returning to a "you are
    // signed out" page immediately after signing in would read as a failure.
    final returnTo = kIsWeb
        ? Uri.base.replace(path: '/dashboard', query: null).toString()
        : 'mymate://dashboard';
    final prefs = await SharedPreferences.getInstance();
    final anonId = prefs.getString('user_id');
    final authUrl = AppConfig.googleAuthUrl(returnTo, anonId: anonId);
    if (authUrl.isEmpty) return;
    // Same tab: a popup opened after an await loses the user-gesture context
    // and gets blocked silently.
    await launchUrl(Uri.parse(authUrl), webOnlyWindowName: '_self');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.scaffoldBackgroundColor,
              Colors.black,
              theme.primaryColor.withValues(alpha: 0.1),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      child: const Icon(
                        Icons.waving_hand_outlined,
                        color: Colors.white70,
                        size: 34,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      "You're signed out",
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Your conversations stay on this device. Sign back in '
                      'whenever you want to pick up where you left off.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white60,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _signInAgain,
                        icon: const Icon(Icons.login, size: 20),
                        label: const Text('Sign in again'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Signed-out browsing is still allowed (20 free replies per
                    // character), so this is a real option, not a way out of a
                    // dialog.
                    TextButton(
                      onPressed: () => context.go('/dashboard'),
                      child: const Text(
                        'Continue without signing in',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
