import 'dart:convert';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_message.dart';
import 'package:state_notifier/state_notifier.dart';

import '../config/app_config.dart';
import 'revenue_cat_service.dart';

final storageServiceProvider = Provider<StorageService>((ref) {
  return StorageService();
});

final userScoreProvider = NotifierProvider<UserScoreNotifier, int>(UserScoreNotifier.new);

class UserScoreNotifier extends Notifier<int> {
  static const String _kUserScoreKey = 'user_score_v1';

  @override
  int build() {
    _loadScore();
    return 0; // Initial state
  }

  Future<void> _loadScore() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getInt(_kUserScoreKey) ?? 0;
  }

  Future<void> increment() async {
    final prefs = await SharedPreferences.getInstance();
    state = state + 1;
    await prefs.setInt(_kUserScoreKey, state);
  }
}

final customCharactersProvider = NotifierProvider<CustomCharactersNotifier, List<Map<String, dynamic>>>(CustomCharactersNotifier.new);

class CustomCharactersNotifier extends Notifier<List<Map<String, dynamic>>> {
  static const String _customCharactersKey = 'custom_characters';

  @override
  List<Map<String, dynamic>> build() {
    _loadCharacters();
    return [];
  }

  Future<void> _loadCharacters() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_customCharactersKey) ?? [];
    state = jsonList.map((jsonStr) => jsonDecode(jsonStr) as Map<String, dynamic>).toList();
  }

  Future<void> addCharacter(Map<String, dynamic> character) async {
    final prefs = await SharedPreferences.getInstance();
    state = [...state, character];
    
    final jsonList = state.map((char) => jsonEncode(char)).toList();
    await prefs.setStringList(_customCharactersKey, jsonList);
  }

  Future<void> deleteCharacter(String characterId) async {
    final prefs = await SharedPreferences.getInstance();
    state = state.where((char) => char['id'] != characterId).toList();
    
    final jsonList = state.map((char) => jsonEncode(char)).toList();
    await prefs.setStringList(_customCharactersKey, jsonList);
  }
}

class StorageService {
  static const String _kChatHistoryKey = 'chat_history_v1';

  Future<int> loadScore() async {
     // Legacy/Helper access
     final prefs = await SharedPreferences.getInstance();
     return prefs.getInt('user_score_v1') ?? 0;
  }

  Future<void> saveMessages(List<ChatMessage> messages, {String chatId = 'default'}) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> encoded = messages.map((msg) {
      return jsonEncode({
        'id': msg.id,
        'text': msg.text,
        'isUser': msg.isUser,
        'isSystem': msg.isSystem, // Save system flag
        'timestamp': msg.timestamp.toIso8601String(),
      });
    }).toList();
    await prefs.setStringList('chat_history_$chatId', encoded);
  }

  Future<List<ChatMessage>> loadMessages({String chatId = 'default'}) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? encoded = prefs.getStringList('chat_history_$chatId');
    
    if (encoded == null) return [];

    return encoded.map((str) {
      final Map<String, dynamic> data = jsonDecode(str);
      return ChatMessage(
        id: data['id'],
        text: data['text'],
        isUser: data['isUser'],
        isSystem: data['isSystem'] ?? false, // Load system flag
        timestamp: DateTime.parse(data['timestamp']),
      );
    }).toList();
  }

  // --- Recent Chats Logic ---
  static const String _kRecentChatsKey = 'recent_chats_v1';
  final _recentChatsController = StreamController<List<Map<String, dynamic>>>.broadcast();

  Stream<List<Map<String, dynamic>>> get recentChatsStream => _recentChatsController.stream;

  Future<void> updateRecentChat({
    required String chatId,
    required String characterName,
    required String characterImage,
    required String lastMessage,
    required DateTime timestamp,
    String? vibe,
    bool incrementUnread = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> currentList = prefs.getStringList(_kRecentChatsKey) ?? [];
    
    // Decode list
    List<Map<String, dynamic>> chats = currentList.map((s) => jsonDecode(s) as Map<String, dynamic>).toList();
    
    int currentUnread = 0;
    
    // Remove existing entry
    final existingIndex = chats.indexWhere((c) => c['chatId'] == chatId);
    if (existingIndex != -1) {
       currentUnread = chats[existingIndex]['unreadCount'] ?? 0;
       chats.removeAt(existingIndex);
    }
    
    // Update unread count
    if (incrementUnread) {
      currentUnread++;
    } else {
      currentUnread = 0; // Reset
    }

    // Add new entry at start
    chats.insert(0, {
      'chatId': chatId,
      'name': characterName,
      'image': characterImage,
      'lastMessage': lastMessage,
      'timestamp': timestamp.toIso8601String(),
      'vibe': vibe ?? 'Gentle',
      'unreadCount': currentUnread,
    });
    
    // Save back
    await prefs.setStringList(_kRecentChatsKey, chats.map((c) => jsonEncode(c)).toList());
    _recentChatsController.add(chats); // Emit update
  }

  Future<void> markChatAsRead(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> currentList = prefs.getStringList(_kRecentChatsKey) ?? [];
    List<Map<String, dynamic>> chats = currentList.map((s) => jsonDecode(s) as Map<String, dynamic>).toList();
    
    final index = chats.indexWhere((c) => c['chatId'] == chatId);
    if (index != -1) {
      chats[index]['unreadCount'] = 0;
      await prefs.setStringList(_kRecentChatsKey, chats.map((c) => jsonEncode(c)).toList());
      _recentChatsController.add(chats); // Emit update
    }
  }

  Future<void> deleteChat(String chatId) async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> currentList = prefs.getStringList(_kRecentChatsKey) ?? [];
    List<Map<String, dynamic>> chats = currentList.map((s) => jsonDecode(s) as Map<String, dynamic>).toList();
    
    chats.removeWhere((c) => c['chatId'] == chatId);
    
    await prefs.setStringList(_kRecentChatsKey, chats.map((c) => jsonEncode(c)).toList());
    
    // Also delete the actual messages to reset history/limits
    final key = 'chat_$chatId';
    await prefs.remove(key); 
    
    _recentChatsController.add(chats);
  }

  Future<List<Map<String, dynamic>>> loadRecentChats() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> currentList = prefs.getStringList(_kRecentChatsKey) ?? [];
    final chats = currentList.map((s) => jsonDecode(s) as Map<String, dynamic>).toList();
    // Emit initial status if controller has listeners? 
    // Usually UI calls this on load, so let's just also emit to be safe if anyone is listening
    _recentChatsController.add(chats);
    return chats;
  }
}

final userSubscriptionProvider = NotifierProvider<UserSubscriptionNotifier, bool>(UserSubscriptionNotifier.new);

class UserSubscriptionNotifier extends Notifier<bool> {
  static const String _kIsPremiumKey = 'is_user_premium';

  @override
  bool build() {
    if (AppConfig.isFreeTier) {
      return true;
    }
    _loadStatus();
    return false; // Default to free
  }

  Future<void> _loadStatus() async {
    if (AppConfig.isFreeTier) {
      state = true;
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    // Load local cache first for immediate UI
    final localStatus = prefs.getBool(_kIsPremiumKey) ?? false;
    state = localStatus;
    
    // Sync with RevenueCat
    try {
      final isRealActive = await RevenueCatService().checkSubscriptionStatus();
      if (localStatus != isRealActive) {
        state = isRealActive;
        await prefs.setBool(_kIsPremiumKey, isRealActive);
      }
    } catch (e) {
      // Fallback to local status if offline/error
    }
  }

  Future<void> setPremium(bool isPremium) async {
    final prefs = await SharedPreferences.getInstance();
    state = isPremium;
    await prefs.setBool(_kIsPremiumKey, isPremium);
  }
}

final messageCountProvider = StateNotifierProvider.family<MessageCountNotifier, int, String>((ref, chatId) {
  return MessageCountNotifier(chatId);
});

class MessageCountNotifier extends StateNotifier<int> {
  final String chatId;

  MessageCountNotifier(this.chatId) : super(0) {
    _loadCount();
  }
  
  String get _key => 'msg_count_$chatId';

  Future<void> _loadCount() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getInt(_key) ?? 0;
  }

  Future<void> increment() async {
    final prefs = await SharedPreferences.getInstance();
    state = state + 1;
    await prefs.setInt(_key, state);
  }
}

final activeChatProvider = NotifierProvider<ActiveChatNotifier, Map<String, String>?>(ActiveChatNotifier.new);

class ActiveChatNotifier extends Notifier<Map<String, String>?> {
  @override
  Map<String, String>? build() {
    return null; // Initial state: No active chat
  }

  void setActive(String name, String vibe) {
    state = {'name': name, 'vibe': vibe};
  }

  void clear() {
    state = null;
  }
}
