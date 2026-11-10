import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/remote_catalogue.dart';
import '../theme/app_theme.dart';

/// Why the app is being held, if it is.
enum AppStop {
  /// Carry on.
  none,

  /// This build is older than the worker still supports.
  update,

  /// The worker has asked every app to hold for a while.
  maintenance,
}

/// The store this build came from, as the worker names them — or null on
/// the web and desktop, which are never asked to update (the web is always
/// the current bundle).
String? appStore() {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    _ => null,
  };
}

/// Whether the app should be held, and why.
///
/// Written so that every doubt resolves to [AppStop.none]:
///  - an unknown build number, an unknown store, a missing or zero minimum:
///    not asked to update;
///  - maintenance only on an answer the worker gave during this launch
///    ([live]) — never on one remembered from an earlier day, so a phone
///    that cannot reach the worker to hear it is over is not locked out;
///  - no catalogue at all (first launch offline, worker down): nothing.
///
/// "Please update" IS honoured from the remembered catalogue: a minimum only
/// ever goes up, and an unsupported build that goes offline is still an
/// unsupported build. It outranks maintenance, since updating is the one
/// thing such a build can usefully be told.
AppStop appStop({
  required RemoteCatalogue catalogue,
  required bool live,
  required int? buildNumber,
  required String? store,
}) {
  final minimum = store == null ? null : catalogue.minBuild[store];
  if (minimum != null && buildNumber != null && buildNumber < minimum) {
    return AppStop.update;
  }
  if (catalogue.maintenance && live) return AppStop.maintenance;
  return AppStop.none;
}

/// Sits above every route and replaces the app with a single screen when the
/// worker says to: "please update" for a build it no longer supports, or
/// "back shortly" while it is being worked on. Both are set in
/// backend/src/catalogue.js (`app`), and neither needs an app release — which
/// is the point: before this, a build in people's hands could not be told
/// anything.
class AppGate extends StatefulWidget {
  final Widget child;

  /// For tests. In the app these come from the platform.
  @visibleForTesting
  final int? debugBuildNumber;
  @visibleForTesting
  final String? debugStore;
  @visibleForTesting
  final bool debugUseOverrides;

  const AppGate({
    super.key,
    required this.child,
    this.debugBuildNumber,
    this.debugStore,
    this.debugUseOverrides = false,
  });

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  int? _buildNumber;
  Timer? _recheck;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    RemoteCatalogue.revision.addListener(_onCatalogue);
    if (widget.debugUseOverrides) {
      _buildNumber = widget.debugBuildNumber;
    } else {
      // Until this answers (or if it never does) the build number is unknown,
      // and an unknown build is never asked to update.
      PackageInfo.fromPlatform().then((info) {
        if (!mounted) return;
        setState(() => _buildNumber = int.tryParse(info.buildNumber));
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    RemoteCatalogue.revision.removeListener(_onCatalogue);
    _recheck?.cancel();
    super.dispose();
  }

  void _onCatalogue() {
    if (mounted) setState(() {});
  }

  String? get _store =>
      widget.debugUseOverrides ? widget.debugStore : appStore();

  AppStop get _stop => appStop(
        catalogue: RemoteCatalogue.current,
        live: RemoteCatalogue.fetchedThisLaunch,
        buildNumber: _buildNumber,
        store: _store,
      );

  /// While held for maintenance, ask again every minute so the screen lifts
  /// on its own. Nothing runs when the app is not held.
  void _syncRecheck(AppStop stop) {
    if (stop == AppStop.maintenance) {
      _recheck ??= Timer.periodic(
        const Duration(minutes: 1),
        (_) => RemoteCatalogue.refresh(force: true),
      );
    } else {
      _recheck?.cancel();
      _recheck = null;
    }
  }

  Future<void> _tryAgain() async {
    setState(() => _checking = true);
    await RemoteCatalogue.refresh(force: true);
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _openStore(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // The screen already says what to do by hand.
    }
  }

  @override
  Widget build(BuildContext context) {
    final stop = _stop;
    _syncRecheck(stop);
    if (stop == AppStop.none) return widget.child;

    final catalogue = RemoteCatalogue.current;
    if (stop == AppStop.update) {
      final url = catalogue.updateUrl[_store];
      final storeName = _store == 'android' ? 'Google Play' : 'the App Store';
      return _StopScreen(
        icon: Icons.system_update,
        title: 'Time to update',
        body: url == null
            ? 'This version of Mythos Live is no longer supported. Open '
                '$storeName and update to carry on.'
            : 'This version of Mythos Live is no longer supported. Update to '
                'carry on where you left off.',
        action: url == null ? null : 'Update',
        onAction: url == null ? null : () => _openStore(url),
      );
    }
    return _StopScreen(
      icon: Icons.hourglass_empty,
      title: 'Back shortly',
      body: catalogue.maintenanceMessage.isNotEmpty
          ? catalogue.maintenanceMessage
          : 'Mythos Live is being looked after. Your chats and coins are '
              'safe. Please try again in a few minutes.',
      action: _checking ? 'Checking…' : 'Try again',
      onAction: _checking ? null : _tryAgain,
    );
  }
}

class _StopScreen extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;

  const _StopScreen({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.secondary;
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: gold, size: 44),
                  const SizedBox(height: 18),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.playfairDisplay(
                      color: AppTheme.inkColor,
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.lato(
                      color: AppTheme.mutedInkColor,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                  if (action != null) ...[
                    const SizedBox(height: 26),
                    FilledButton(
                      onPressed: onAction,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 4),
                        child: Text(action!),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
