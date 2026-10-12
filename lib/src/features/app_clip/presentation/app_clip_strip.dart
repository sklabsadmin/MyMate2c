import 'package:flutter/material.dart';

import '../../../core/services/app_clip.dart';

/// A strip under the whole app while it runs as an App Clip: the one place
/// the Clip points at the full app. Tapping it shows the App Store overlay.
///
/// A Clip has no coin store (in-app purchase is reserved for the full app),
/// no notifications and no custom URL scheme, so this is also how a visitor
/// who wants those finds their way to them.
class AppClipStrip extends StatelessWidget {
  const AppClipStrip({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(child: child),
        Material(
          color: theme.colorScheme.surface,
          child: SafeArea(
            top: false,
            child: InkWell(
              onTap: AppClip.showAppStoreOverlay,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'This is a preview. Get the full Mythos Live app.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Get',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
