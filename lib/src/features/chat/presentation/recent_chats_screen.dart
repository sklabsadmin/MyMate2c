import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../../core/services/storage_service.dart';

class RecentChatsScreen extends ConsumerStatefulWidget {
  const RecentChatsScreen({super.key});

  @override
  ConsumerState<RecentChatsScreen> createState() => _RecentChatsScreenState();
}

class _RecentChatsScreenState extends ConsumerState<RecentChatsScreen> {
  List<Map<String, dynamic>> _recentChats = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  Future<void> _loadChats() async {
    final storage = ref.read(storageServiceProvider);
    final chats = await storage.loadRecentChats();
    if (mounted) {
      setState(() {
        _recentChats = chats;
        _isLoading = false;
      });
    }
  }

  // Reload when coming back to view
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadChats();
  }

  String _formatTime(String timestamp) {
    final date = DateTime.parse(timestamp);
    final now = DateTime.now();
    
    if (now.difference(date).inDays == 0) {
      return DateFormat('h:mm a').format(date);
    } else if (now.difference(date).inDays < 7) {
      return DateFormat('EEE').format(date);
    } else {
      return DateFormat('MMM d').format(date);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final storage = ref.watch(storageServiceProvider);

    // Trigger load to ensure stream has data
    // We can do this in initState, but let's ensure it's called
    // storage.loadRecentChats(); // Handled in initState

    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: theme.textTheme.headlineMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
      extendBodyBehindAppBar: true, 
      body: Stack(
        children: [
           // Background
           Container(
             decoration: BoxDecoration(
               gradient: LinearGradient(
                 begin: Alignment.topCenter,
                 end: Alignment.bottomCenter,
                 colors: [
                   const Color(0xFF2E003E), // Deep Purple
                   Colors.black,
                 ],
               ),
             ),
           ),
           
           StreamBuilder<List<Map<String, dynamic>>>(
             stream: storage.recentChatsStream,
             builder: (context, snapshot) {
               if (snapshot.connectionState == ConnectionState.waiting && _isLoading) {
                 return const Center(child: CircularProgressIndicator());
               }
               
               final chats = snapshot.data ?? _recentChats; // Fallback to loaded data

               if (chats.isEmpty && !_isLoading) {
                 return _buildEmptyState(theme);
               }

               return ListView.builder(
                 padding: const EdgeInsets.only(top: 100), // Space for transparent app bar
                 itemCount: chats.length,
                 itemBuilder: (context, index) {
                   final chat = chats[index];
                   return Dismissible(
                     key: Key(chat['chatId']),
                     direction: DismissDirection.endToStart,
                     background: Container(
                       alignment: Alignment.centerRight,
                       padding: const EdgeInsets.only(right: 20),
                       color: Colors.red,
                       child: const Icon(Icons.delete, color: Colors.white),
                     ),
                     confirmDismiss: (direction) async {
                        final isPremium = ref.read(userSubscriptionProvider);
                        if (!isPremium) {
                           context.push('/paywall');
                           return false; // Don't delete
                        }
                        return await showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                             title: const Text('Delete Chat?'),
                             content: const Text('This action cannot be undone.'),
                             actions: [
                               TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                               TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
                             ],
                          ),
                        );
                     },
                     onDismissed: (direction) {
                       storage.deleteChat(chat['chatId']);
                     },
                     child: _buildChatTile(chat, theme),
                   );
                 },
               );
             },
           ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64, color: Colors.white.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text(
            "No messages yet",
            style: theme.textTheme.titleLarge?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 8),
          Text(
            "Start talking to someone from the Dashboard!",
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white38),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => context.go('/dashboard'),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.primaryColor,
              foregroundColor: Colors.white,
            ),
            child: const Text("Go to Dashboard"),
          ),
        ],
      ),
    );
  }

  Widget _buildChatTile(Map<String, dynamic> chat, ThemeData theme) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: theme.primaryColor.withOpacity(0.5), width: 2),
          image: DecorationImage(
            image: AssetImage(chat['image']),
            fit: BoxFit.cover,
          ),
        ),
      ),
      title: Text(
        chat['name'],
        style: GoogleFonts.outfit(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            chat['lastMessage'],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatTime(chat['timestamp']),
            style: theme.textTheme.bodySmall?.copyWith(
              color: (chat['unreadCount'] ?? 0) > 0 ? theme.primaryColor : Colors.white38,
              fontWeight: (chat['unreadCount'] ?? 0) > 0 ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if ((chat['unreadCount'] ?? 0) > 0)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: theme.primaryColor,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${chat['unreadCount']}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
      onTap: () {
        context.push('/chat/session?scenario=${Uri.encodeComponent(chat['chatId'])}&characterImage=${Uri.encodeComponent(chat['image'])}&isRoleplay=false');
      },
      onLongPress: () async {
        final isPremium = ref.read(userSubscriptionProvider);
        if (!isPremium) {
           context.push('/paywall');
           return;
        }
        
        final shouldDelete = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
             title: const Text('Delete Chat?'),
             content: const Text('This action cannot be undone.'),
             actions: [
               TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
               TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
             ],
          ),
        );

        if (shouldDelete == true) {
          if (!mounted) return;
           final storage = ref.read(storageServiceProvider);
           storage.deleteChat(chat['chatId']);
        }
      },
    );
  }
}
