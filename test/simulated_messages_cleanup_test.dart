// Build 99 and earlier ran a "background chat simulator" on iOS/Android: every
// 45s it wrote a canned line from a random recent character into that chat's
// history (id prefix 'bg_') and bumped its unread count. The lines were then
// sent to the model as the character's own turns. These tests pin the cleanup
// for installs that already have them on disk, and the rule that decides when
// the "you left mid-thought" notification may be scheduled.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mythos_live/src/app.dart';
import 'package:mythos_live/src/core/models/chat_message.dart';
import 'package:mythos_live/src/core/services/storage_service.dart';

String _msg(String id, String text, bool isUser, DateTime at) =>
    jsonEncode(ChatMessage(id: id, text: text, isUser: isUser, timestamp: at)
        .toJson());

void main() {
  final t0 = DateTime(2026, 10, 30, 9);

  test('simulated lines are dropped from a chat when it loads', () async {
    SharedPreferences.setMockInitialValues({
      'chat_history_odysseus': [
        _msg('1', 'Hello, Odysseus.', true, t0),
        _msg('2', 'Well now.', false, t0.add(const Duration(minutes: 1))),
        _msg('bg_1761800000000', 'The gods are bored. So am I.', false,
            t0.add(const Duration(hours: 1))),
        _msg('bg_1761800045000', 'Tell me something I do not know.', false,
            t0.add(const Duration(hours: 2))),
      ],
    });

    final history = await StorageService().loadMessages(chatId: 'odysseus');

    expect(history.map((m) => m.id), ['1', '2'],
        reason: 'nothing the simulator wrote may reach the screen or the '
            'model as the character having said it');
  });

  test('a fake unread badge is reset to the last real message', () async {
    final real = t0.add(const Duration(minutes: 1));
    final fake = t0.add(const Duration(hours: 3));
    SharedPreferences.setMockInitialValues({
      'chat_history_odysseus': [
        _msg('1', 'Hello, Odysseus.', true, t0),
        _msg('2', 'Well now.', false, real),
        _msg('bg_1', 'The gods are bored. So am I.', false, fake),
      ],
      'recent_chats_v1': [
        // The simulator's write: preview, timestamp and unread all fake, and
        // the entry moved to the top.
        jsonEncode({
          'chatId': 'odysseus',
          'name': 'Odysseus',
          'image': 'assets/images/odysseus.jpg',
          'lastMessage': 'The gods are bored. So am I.',
          'timestamp': fake.toIso8601String(),
          'unreadCount': 3,
        }),
        jsonEncode({
          'chatId': 'zeus',
          'name': 'Zeus',
          'image': 'assets/images/zeus.jpg',
          'lastMessage': 'Speak.',
          'timestamp': t0.add(const Duration(hours: 2)).toIso8601String(),
          'unreadCount': 0,
        }),
      ],
    });

    final chats = await StorageService().loadRecentChats();

    final odysseus = chats.firstWhere((c) => c['chatId'] == 'odysseus');
    expect(odysseus['unreadCount'], 0);
    expect(odysseus['lastMessage'], 'Well now.');
    expect(odysseus['timestamp'], real.toIso8601String());
    expect(chats.map((c) => c['chatId']), ['zeus', 'odysseus'],
        reason: 'back in its real place, behind the chat that was actually '
            'more recent');

    // Persisted, so the repair is not redone, and undone, on every read.
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs
        .getStringList('recent_chats_v1')!
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .toList();
    expect(stored.first['chatId'], 'zeus');
    expect(stored.last['unreadCount'], 0);
  });

  test('only an open conversation counts as leaving mid-chat', () {
    expect(isConversationPath('/chat/session'), isTrue);
    expect(isConversationPath('/c/odysseus'), isTrue);
    expect(isConversationPath('/chat'), isFalse,
        reason: 'the recent-chats list is not a conversation');
    expect(isConversationPath('/dashboard'), isFalse);
    expect(isConversationPath('/settings'), isFalse);
    expect(isConversationPath('/coins'), isFalse);
    expect(isConversationPath(''), isFalse);
  });
}
