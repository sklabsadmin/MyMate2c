import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../core/config/app_config.dart';

/// Holding page shown before the app while [AppConfig.showMaintenanceGate] is
/// true, so casual visitors don't wander through a work-in-progress build.
///
/// It is a soft gate, not security: pressing Tab (or the long-press fallback
/// on touch devices, which have no Tab key) drops straight into the real app
/// with everything working as normal. Anyone determined can get past it, which
/// is the intent — it filters people who don't know the trick, nothing more.
class MaintenanceScreen extends StatefulWidget {
  const MaintenanceScreen({super.key});

  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Grab focus so the Tab key reaches us without the user clicking first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _enterApp() {
    AppConfig.maintenanceGateBypassed = true;
    if (mounted) context.go('/dashboard');
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.tab) {
      _enterApp();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      autofocus: true,
      child: Scaffold(
        body: GestureDetector(
          // Touch devices have no Tab key, so a long press on the artwork is
          // the equivalent way in.
          onLongPress: _enterApp,
          child: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.scaffoldBackgroundColor,
                  Colors.black,
                  theme.primaryColor.withOpacity(0.12),
                ],
              ),
            ),
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 24,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: theme.primaryColor.withOpacity(0.25),
                                blurRadius: 60,
                                spreadRadius: 8,
                              ),
                            ],
                          ),
                          child: ClipOval(
                            child: Image.asset(
                              'assets/images/app_icon.png',
                              width: 132,
                              height: 132,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(height: 40),
                        Text(
                          'The Greek Interactive Experience',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.displayLarge?.copyWith(
                            fontSize: 26,
                            color: Colors.white,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'is undergoing a personality change.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: Colors.white70,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Please come back again tomorrow.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: Colors.white70,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 44),
                        Container(
                          width: 56,
                          height: 2,
                          decoration: BoxDecoration(
                            color: theme.primaryColor.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
