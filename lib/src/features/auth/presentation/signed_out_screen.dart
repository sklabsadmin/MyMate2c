import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_theme.dart';
import 'sign_in_sheet.dart';

/// Where sign-out lands, instead of dropping straight back into Settings.
///
/// Signing out used to bounce back to /settings, which looked identical to the
/// screen you had just been on — nothing confirmed that anything happened. This
/// is a deliberate dead end: it sits here until you choose to sign back in or
/// to carry on signed out, so the sign-out is unmistakably complete.
///
/// Deliberately outside the nav shell — no bottom bar — so it cannot be
/// wandered away from by accident.
class SignedOutScreen extends ConsumerWidget {
  const SignedOutScreen({super.key});

  // Come back to the dashboard rather than here: returning to a "you are
  // signed out" page immediately after signing in would read as a failure.
  String get _returnTo => kIsWeb
      ? Uri.base.replace(path: '/dashboard', query: null).toString()
      : 'mythoslive://dashboard';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // /signed-out?deleted=1 is where account deletion lands on the web.
    final deleted =
        GoRouterState.of(context).uri.queryParameters['deleted'] == '1';

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppTheme.backgroundColor, // White
              AppTheme.surfaceColor, // Soft Blush
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
                        color: AppTheme.panelColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppTheme.hairlineColor,
                        ),
                      ),
                      child: const Icon(
                        Icons.waving_hand_outlined,
                        color: AppTheme.mutedInkColor,
                        size: 34,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      deleted ? 'Your account was deleted' : "You're signed out",
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: AppTheme.inkColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      deleted
                          ? 'Your account and its saved data are gone. You can '
                              'keep chatting without one, or sign in again to '
                              'start a fresh account.'
                          : 'Your conversations stay on this device. Sign back in '
                              'whenever you want to pick up where you left off.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.mutedInkColor,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 32),
                    if (AuthNotifier.signInAvailable)
                      SignInButtons(
                        onChoose: (provider) async {
                          final outcome = await runSignIn(
                              context, ref, provider,
                              returnTo: _returnTo);
                          // Native completes in place (the web navigates
                          // away): leave the "signed out" page ourselves.
                          if (outcome == SignInOutcome.signedIn &&
                              context.mounted) {
                            context.go('/dashboard');
                          }
                        },
                      ),
                    const SizedBox(height: 12),
                    // Signed-out browsing is still allowed (20 free replies per
                    // character), so this is a real option, not a way out of a
                    // dialog.
                    TextButton(
                      onPressed: () => context.go('/dashboard'),
                      child: const Text(
                        'Continue without signing in',
                        style: TextStyle(color: AppTheme.mutedInkColor),
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
