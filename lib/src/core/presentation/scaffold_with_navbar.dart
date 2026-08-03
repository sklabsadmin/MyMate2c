import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_config.dart';
import '../services/keyboard_inset.dart';

class ScaffoldWithNavBar extends StatelessWidget {
  const ScaffoldWithNavBar({
    required this.navigationShell,
    Key? key,
  }) : super(key: key ?? const ValueKey<String>('ScaffoldWithNavBar'));

  final StatefulNavigationShell navigationShell;

  void _goBranch(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Cap and centre the entire shell — body AND nav bar together, so they
    // stay the same width as each other. The MediaQuery override is what
    // makes this safe: descendants sizing themselves off
    // MediaQuery.size.width (the chat bubbles' 0.62/0.75 caps) would
    // otherwise measure the whole window and overflow the column.
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppConfig.maxShellWidth),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final media = MediaQuery.of(context);
              // iOS does not shrink the layout viewport for the keyboard, so
              // Flutter web can report viewInsets.bottom as 0 while the
              // keyboard is covering the bottom of the page — which leaves the
              // chat composer underneath it, being typed into unseen. Take
              // whichever figure is larger: on every platform that reports the
              // keyboard properly this is the framework's own value and nothing
              // changes, and it can never be added twice.
              return ValueListenableBuilder<double>(
                valueListenable: keyboardInset,
                builder: (context, measured, _) {
                  final bottom = math.max(media.viewInsets.bottom, measured);
                  return MediaQuery(
                    data: media.copyWith(
                      size: Size(constraints.maxWidth, media.size.height),
                      viewInsets: media.viewInsets.copyWith(bottom: bottom),
                    ),
                    child: _buildShell(context, theme),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  /// Opt-in readout of what the browser is telling us about the viewport,
  /// shown only for ?vpdebug=1. A phone has no console to inspect, and these
  /// four numbers are the whole diagnosis for "the keyboard covers the
  /// composer": if `hidden` stays 0 while the keyboard is up, the browser is
  /// not reporting it and no amount of Flutter-side layout will help.
  Widget _viewportDebugBanner(BuildContext context) {
    final report = keyboardInsetDebug();
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: IgnorePointer(
        child: ColoredBox(
          color: Colors.black87,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              '$report · viewInsets ${insets.toStringAsFixed(0)}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.greenAccent,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShell(BuildContext context, ThemeData theme) {
    final showDebug = Uri.base.queryParameters['vpdebug'] == '1';
    return Scaffold(
      body: showDebug
          ? Stack(
              children: [
                navigationShell,
                _viewportDebugBanner(context),
              ],
            )
          : navigationShell,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
           color: theme.scaffoldBackgroundColor, // Ensure blend
           border: Border(top: BorderSide(color: theme.primaryColor.withOpacity(0.1))),
           boxShadow: [
             BoxShadow(
               color: Colors.black.withOpacity(0.3),
               blurRadius: 10,
               offset: const Offset(0, -2),
             ),
           ],
        ),
        child: Theme(
          data: theme.copyWith(
            canvasColor: theme.scaffoldBackgroundColor, 
          ),
          child: NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _goBranch,
            backgroundColor: theme.scaffoldBackgroundColor,
            indicatorColor: theme.primaryColor.withOpacity(0.2),
            height: 65,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysHide, // Sexier, minimal
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard, color: Color(0xFFD81B60)),
                label: 'Personalities',
              ),
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble, color: Color(0xFFD81B60)),
                label: 'Conversations',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person, color: Color(0xFFD81B60)),
                label: 'My Profile',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
