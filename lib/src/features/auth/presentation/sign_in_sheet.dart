import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../core/config/app_config.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../wallet/coin_wallet.dart';

/// Apple and Google, together, everywhere sign-in is offered.
///
/// App Review 4.8: an app that offers Google sign-in must offer Sign in with
/// Apple as an equivalent option, so no screen draws one without the other —
/// every entry point goes through this widget. Apple uses the package's own
/// button, which follows Apple's Human Interface Guidelines; Google's sits
/// beside it at the same size and weight.
class SignInButtons extends StatelessWidget {
  const SignInButtons({super.key, required this.onChoose});

  final void Function(SignInProvider provider) onChoose;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (AuthNotifier.appleAvailable) ...[
          SignInWithAppleButton(
            text: 'Continue with Apple',
            height: 50,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            onPressed: () => onChoose(SignInProvider.apple),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          height: 50,
          child: OutlinedButton(
            onPressed: () => onChoose(SignInProvider.google),
            style: OutlinedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF1F1F1F),
              side: const BorderSide(color: Color(0xFF747775)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // TODO(brand): swap for the official Google "G" mark from
                // Google's sign-in branding kit (assets/images/google_g.png).
                const Icon(Icons.g_mobiledata, size: 30),
                const SizedBox(width: 6),
                Text(
                  'Continue with Google',
                  style: GoogleFonts.roboto(fontSize: 17, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Runs a sign-in and tells the person how it went. Returns the outcome so
/// callers can carry on (re-sync a profile, close a sheet) only on success.
Future<SignInOutcome> runSignIn(
  BuildContext context,
  WidgetRef ref,
  SignInProvider provider, {
  String? returnTo,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await ref
      .read(authProvider.notifier)
      .signIn(provider, returnTo: returnTo);
  switch (outcome) {
    case SignInOutcome.signedIn:
      final who = ref.read(authProvider).value;
      messenger?.showSnackBar(SnackBar(
        content: Text('Signed in with ${who?.providerLabel ?? provider.name}. '
            'Your chats and coins are saved to your account.'),
      ));
    case SignInOutcome.failed:
      messenger?.showSnackBar(const SnackBar(
        content: Text("Couldn't sign in just now. Please try again."),
      ));
    case SignInOutcome.cancelled:
    case SignInOutcome.redirected:
      break;
  }
  return outcome;
}

/// The bottom sheet offering sign-in. [title] and [message] say why it is
/// being offered right now; the buttons and the coin line are the same
/// everywhere. Resolves to the outcome, or null if dismissed.
Future<SignInOutcome?> showSignInSheet(
  BuildContext context,
  WidgetRef ref, {
  String title = 'Keep your chats and coins',
  String message =
      'Sign in to keep your conversations and coins safe, and to pick up '
          'where you left off on any device.',
  String? returnTo,
}) async {
  final coinsLive = AppConfig.coinsUiEnabled &&
      (ref.read(coinWalletProvider).value?.enabled ?? false);
  final hasLinkedBefore = await AuthNotifier.hasEverLinked();
  if (!context.mounted) return null;

  final provider = await showModalBottomSheet<SignInProvider>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return Container(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: AppTheme.hairlineColor),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.favorite, color: theme.primaryColor, size: 36),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.playfairDisplay(
                color: AppTheme.inkColor,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.lato(
                color: AppTheme.mutedInkColor,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            // The link bonus is paid once per account, so it is only promised
            // to someone who has never linked on this device.
            if (coinsLive && !hasLinkedBefore) ...[
              const SizedBox(height: 10),
              Text(
                'Signing in adds +100 coins.',
                textAlign: TextAlign.center,
                style: GoogleFonts.lato(
                  color: AppTheme.goldInkColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 22),
            SignInButtons(
              onChoose: (p) => Navigator.of(sheetContext).pop(p),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: Text(
                'Not now',
                style: GoogleFonts.lato(color: AppTheme.mutedInkColor),
              ),
            ),
          ],
        ),
      );
    },
  );
  if (provider == null || !context.mounted) return null;
  return runSignIn(context, ref, provider, returnTo: returnTo);
}
