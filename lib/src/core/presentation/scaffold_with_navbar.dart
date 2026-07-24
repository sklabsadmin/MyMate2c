import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

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
    
    return Scaffold(
      body: navigationShell,
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
                label: 'Dashboard',
              ),
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble, color: Color(0xFFD81B60)),
                label: 'Chats',
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
