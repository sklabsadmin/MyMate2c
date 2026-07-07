import 'dart:async';
import 'dart:math';
import 'storage_service.dart';
import '../models/chat_message.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class BackgroundChatSimulator {
  Timer? _timer;
  final Ref ref;

  BackgroundChatSimulator(this.ref);

  void start() {
    _timer?.cancel();
    if (kIsWeb) return;

    // Check every 45 seconds (short for demo)
    _timer = Timer.periodic(const Duration(seconds: 45), (timer) async {
      await _simulateEngagement();
    });
  }

  void stop() {
    _timer?.cancel();
  }

  Future<void> _simulateEngagement() async {
    final storage = ref.read(storageServiceProvider);
    final activeChat = ref.read(activeChatProvider); // {name, vibe}
    
    // 1. Load Recent Chats
    final recentChats = await storage.loadRecentChats();
    if (recentChats.isEmpty) return;

    // 2. Pick a candidate
    // Filter out the one currently Active (if any)
    final candidates = recentChats.where((chat) {
       // If activeChat is set, compare names/IDs
       if (activeChat != null && activeChat['name'] == chat['name']) {
         return false;
       }
       return true;
    }).toList();

    if (candidates.isEmpty) return;

    // 3. Random choice
    final random = Random();
    final chat = candidates[random.nextInt(candidates.length)];
    
    // 4. Generate Message
    final messageText = _generateHook(chat['vibe'] ?? 'Gentle');
    
    // 5. Save Message to History
    // We need to append this message to the chat history so when user opens it, it's there.
    // This requires loading history, adding, saving.
    final chatId = chat['chatId'];
    List<ChatMessage> history = await storage.loadMessages(chatId: chatId);
    
    final newMessage = ChatMessage(
      id: 'bg_${DateTime.now().millisecondsSinceEpoch}',
      text: messageText,
      isUser: false,
      timestamp: DateTime.now(),
    );
    
    history.add(newMessage);
    await storage.saveMessages(history, chatId: chatId);

    // 6. Update Recent List with Unread Count
    await storage.updateRecentChat(
      chatId: chatId,
      characterName: chat['name'],
      characterImage: chat['image'],
      lastMessage: messageText,
      timestamp: DateTime.now(),
      vibe: chat['vibe'],
      incrementUnread: true,
    );
    
    print("Background Simulation: Sent '$messageText' from ${chat['name']}");
  }

  String _generateHook(String vibe) {
    final hooks = {
      'Gentle': [
        "I was just thinking about you... 💕",
        "Hope your day is going well.",
        "I miss your voice.",
      ],
      'Dominant': [
        "Why haven't you replied?",
        "I'm waiting.",
        "Don't make me come find you.",
      ],
      'Playful': [
        "Boop! 👉👃",
        "Guess what I'm wearing? 😜",
        "Bored... entertain me!",
      ],
      'Intellectual': [
        "I had a thought about our last conversation...",
        "Do you have a moment to discuss something?",
        "I miss your mind.",
      ],
    };

    final list = hooks[vibe] ?? hooks['Gentle']!;
    return list[Random().nextInt(list.length)];
  }
}

final backgroundChatSimulatorProvider = Provider<BackgroundChatSimulator>((ref) {
  return BackgroundChatSimulator(ref);
});
