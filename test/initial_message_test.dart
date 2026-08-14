// Behaviour tests for ChatScreen.initialMessage — the opener tapped on a
// profile card's "Ask Me About", and the same thing carried on a
// /c/<id>?initialMessage=... campaign link.
//
// The bug they exist to catch: initState fires _loadHistory() without awaiting
// it, and that is the only thing that ever builds the OpenAIService, behind two
// awaits on storage. The opener used to be sent from the first post-frame
// callback, so on a cold load it got there first — the user's bubble was drawn
// and saved, the typing indicator came on, and _handleSend hit the null service
// and returned. No request was ever made and the indicator span for as long as
// the tab stayed open. Nothing about that is visible in a screenshot of the
// moment; it needs the conversation read back.
//
// The API call fails here — flutter_test answers every HTTP request with a 400,
// and there is no worker to talk to anyway — which is what makes these useful
// rather than a limitation: the character's "trouble thinking" fallback is
// produced *after* the send has gone through the service, so its arrival is
// proof that the call was made. Under the bug nothing arrived at all.

import 'dart:convert';

import 'package:ai_boyfriend_chat/src/features/chat/presentation/chat_screen.dart';
import 'package:ai_boyfriend_chat/src/core/models/chat_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _scenario = 'Odysseus (King of Ithaca)';
const String _historyKey = 'chat_history_$_scenario';

/// The opener. Any of the character's own "Ask Me About" questions would do;
/// this one is deliberately not one _wantsPhoto matches, since a photo request
/// is answered from assets and never reaches the service at all.
const String _opener = 'What happened when you finally reached Ithaca?';

/// [logicalSize] matches the other widget tests: _StarterPrompts thins itself
/// out below 720 logical pixels, which has nothing to do with what is under
/// test here but changes what is on screen.
Future<void> _mountChat(
  WidgetTester tester, {
  String? initialMessage,
  Size logicalSize = const Size(390, 844),
}) async {
  tester.view.physicalSize = logicalSize * 3.0;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: ChatScreen(
          scenario: _scenario,
          characterId: 'odysseus',
          initialMessage: initialMessage,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

/// The conversation as it was actually persisted. Read from storage rather than
/// from the tree because the message list is a virtualised ListView, so
/// find.text misses anything scrolled out of view.
Future<List<ChatMessage>> _history() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_historyKey) ?? const [];
  return raw
      .map((s) => ChatMessage.fromJson(jsonDecode(s) as Map<String, dynamic>))
      .toList();
}

/// Runs the virtual clock forward until [stopWhen] holds or [limit] runs out.
///
/// A reply is paced by a random 2–5s bubble delay on top of however long the
/// request takes, so the window has to cover the worst case; stopping early
/// keeps the idle nudge (14s of quiet) out of the conversation being asserted
/// on.
Future<void> _run(
  WidgetTester tester, {
  Duration limit = const Duration(seconds: 12),
  Duration step = const Duration(milliseconds: 100),
  Future<bool> Function()? stopWhen,
}) async {
  var elapsed = 0;
  while (elapsed < limit.inMilliseconds) {
    await tester.pump(step);
    elapsed += step.inMilliseconds;
    if (stopWhen != null && await stopWhen()) return;
  }
}

Future<bool> _replyArrived() async =>
    (await _history()).any((m) => !m.isUser && !m.isSystem);

/// Whether the typing indicator is on screen.
///
/// Detected by the rotating status phrases _TypingBubble shows ("Odysseus is
/// considering your question…"), since the widget itself is private. They only
/// appear after one 4s interval, so this is only meaningful once the clock has
/// been run past that — which is exactly the case that matters: an indicator
/// left on by an early return stays on forever.
///
/// The ellipsis is what separates a phrase from the fallback reply, which also
/// begins "Odysseus is " but ends in three full stops.
bool _typingIndicatorVisible(WidgetTester tester) {
  return tester.widgetList<Text>(find.byType(Text)).any((t) {
    final s = t.data ?? '';
    return s.startsWith('Odysseus is ') && s.endsWith('…');
  });
}

/// Unmounts and runs the clock out: the reply pacing and the script player are
/// uncancellable Future.delayed chains, and flutter_test fails a test that
/// leaves a Timer pending.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(minutes: 1));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // OpenAIService reads AppConfig as it is constructed, which throws if
    // dotenv was never loaded. Nothing here reaches a real backend, so the
    // values only have to exist.
    dotenv.loadFromString(
      envString: 'WORKER_URL=http://localhost\nAPP_SECRET=test',
    );
  });

  testWidgets('an opener on a cold load is answered, not left hanging',
      (tester) async {
    await _mountChat(tester, initialMessage: _opener);
    await _run(tester, stopWhen: _replyArrived);

    final history = await _history();
    final asked = history.where((m) => m.isUser).toList();
    final replies = history.where((m) => !m.isUser && !m.isSystem).toList();

    expect(asked.map((m) => m.text), [_opener],
        reason: 'the opener should be sent exactly once');
    // The point of the test. Before the fix this was empty: the send bailed on
    // a service that _loadHistory had not built yet.
    expect(replies, isNotEmpty, reason: 'the send never reached the service');
    expect(history.indexOf(replies.first), greaterThan(history.indexOf(asked.first)),
        reason: 'the reply should follow the question');

    await _teardown(tester);
  });

  testWidgets('the typing indicator is cleared by a send that fails',
      (tester) async {
    await _mountChat(tester, initialMessage: _opener);
    await _run(tester, stopWhen: _replyArrived);

    // Past two of the indicator's 4s status intervals, and still short of the
    // 14s idle nudge. If anything had left _isTyping on, a phrase would be on
    // screen by now.
    await _run(tester, limit: const Duration(seconds: 9));
    expect(_typingIndicatorVisible(tester), isFalse);

    await _teardown(tester);
  });

  testWidgets('a reload does not ask the opener a second time', (tester) async {
    // What the address bar hands back on every refresh of
    // /c/odysseus?initialMessage=..., against a conversation that already has
    // the exchange in it.
    final answered = [
      ChatMessage(
        id: 'u1',
        text: _opener,
        isUser: true,
        timestamp: DateTime(2026, 1, 1, 12),
      ),
      ChatMessage(
        id: 'a1',
        text: 'Twenty years, and the dog knew me first.',
        isUser: false,
        timestamp: DateTime(2026, 1, 1, 12, 0, 5),
      ),
    ];
    SharedPreferences.setMockInitialValues({
      _historyKey: answered.map((m) => jsonEncode(m.toJson())).toList(),
    });

    await _mountChat(tester, initialMessage: _opener);
    await _run(tester, limit: const Duration(seconds: 8));

    final history = await _history();
    expect(history.where((m) => m.isUser).length, 1);
    expect(history.length, 2, reason: 'nothing should have been sent');

    await _teardown(tester);
  });

}

