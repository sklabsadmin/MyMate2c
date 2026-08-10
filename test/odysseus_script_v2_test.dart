// Behaviour tests for Odysseus's scripted opening v2.
//
// These drive the real ChatScreen rather than a copy of its logic, because
// every bug this file is here to catch lives in the interaction between the
// script data, the player's timing and the quick-reply strip's index — none of
// which a unit test of the constants would exercise.
//
// Timing is asserted against flutter_test's virtual clock, so "6.2 seconds" is
// exact and instant rather than a real wait. That matters: the same numbers
// cannot be measured in a browser, where a backgrounded tab is throttled to 1Hz
// and quantises every delay to a whole second.
//
// Arrivals are read from the persisted history rather than from the widget
// tree. _addMessage writes through to SharedPreferences on every bubble, and
// the message list is a virtualised ListView whose off-screen bubbles are not
// built — so find.text() silently misses most of a 51-bubble script.

import 'dart:convert';

import 'package:ai_boyfriend_chat/src/features/chat/presentation/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _scenario = 'Odysseus (King of Ithaca)';
const String _historyKey = 'chat_history_$_scenario';

/// The first and last line of each of the twelve turns, which is all these
/// tests need to identify a turn boundary. Deliberately a restatement rather
/// than a read of the private constant: if someone edits the script, these
/// tests should fail and be updated on purpose, not silently follow along.
const String _firstLine = 'Well now...';
const String _p01Question = 'What have you heard?';
const String _p02FirstLine = 'No verdict yet? Fair enough.';
const String _p02Question = 'Would you rather hear about a monster, a '
    'beautiful island... or one of my truly terrible decisions?';
const String _p12Question = 'Where should we begin?';

/// Quick replies for the first two pauses, and one of the cold-safe sets the
/// strip falls back to once the script is interrupted.
const List<String> _set01 = [
  'The Trojan Horse, of course.',
  'Mostly your adventures.',
  'I know about you and Penelope.',
];
const List<String> _set02 = [
  'The terrible decision.',
  'Tell me about the island.',
  'Definitely the monster.',
];
const List<String> _coldSafeSets = [
  'What happened when you finally reached Ithaca?',
  'What is the strangest place you ever landed?',
  'What have you changed your mind about?',
  'What should I ask you that nobody ever does?',
];

Future<void> _mountChat(WidgetTester tester) async {
  // A phone, not flutter_test's default 800x600. _StarterPrompts drops to two
  // rows below 720 logical pixels, so on the default surface the third quick
  // reply is legitimately absent and every assertion about a full set fails
  // for a reason that has nothing to do with the script.
  tester.view.physicalSize = const Size(1170, 2532); // iPhone 13, 390x844 @3x
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        home: ChatScreen(scenario: _scenario, characterId: 'odysseus'),
      ),
    ),
  );
  // Let initState's async work (history load, prefs) settle without advancing
  // far enough for the first bubble, whose typing beat is 315ms.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

/// Every character line delivered so far, in order.
Future<List<String>> _delivered() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_historyKey) ?? const [];
  return raw
      .map((s) => jsonDecode(s) as Map<String, dynamic>)
      .where((m) => m['isUser'] != true && m['isSystem'] != true)
      .map((m) => m['text'] as String)
      .toList();
}

/// Runs the virtual clock forward in [step] slices, recording the elapsed time
/// at which each line first appears. Stepping rather than jumping is what makes
/// the timings observable at all — a single long pump would deliver the whole
/// script and lose the order it arrived in.
Future<Map<String, int>> _play(
  WidgetTester tester, {
  required Duration limit,
  Duration step = const Duration(milliseconds: 50),
  bool Function(List<String> delivered)? stopWhen,
}) async {
  final arrivals = <String, int>{};
  var elapsed = 0;
  while (elapsed < limit.inMilliseconds) {
    await tester.pump(step);
    elapsed += step.inMilliseconds;
    final lines = await _delivered();
    for (final line in lines) {
      arrivals.putIfAbsent(line, () => elapsed);
    }
    if (stopWhen != null && stopWhen(lines)) break;
  }
  return arrivals;
}

/// Unmounts the screen and lets the clock run out; flutter_test fails a test
/// that leaves a Timer pending.
///
/// dispose() cancels the two timers the screen owns, but the script player and
/// the reply pacing are chains of `Future.delayed`, and those are not
/// cancellable — an abandoned run is still parked on one. So the tree is torn
/// down first, which makes every continuation take its `mounted` early return,
/// and then the clock is run past the longest of them.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(minutes: 1));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // OpenAIService is constructed during _loadHistory and reads AppConfig,
    // which throws if dotenv was never loaded. Nothing here sends, so the
    // values only have to exist.
    dotenv.loadFromString(
      envString: 'WORKER_URL=http://localhost\nAPP_SECRET=test',
    );
  });

  testWidgets('plays all twelve turns, in order, into an empty chat',
      (tester) async {
    await _mountChat(tester);
    // Stops at the closing line rather than running on: once the script ends
    // the idle timer starts posting nudges, which are not script bubbles and
    // would inflate the count.
    await _play(
      tester,
      limit: const Duration(seconds: 200),
      stopWhen: (lines) => lines.contains(_p12Question),
    );

    final lines = await _delivered();
    expect(lines.length, 51, reason: 'v2 is 12 turns / 51 bubbles');
    expect(lines.first, _firstLine);
    expect(lines.last, _p12Question);
    // Every turn ends on a question to the visitor — the whole point of v2.
    expect(lines[4], _p01Question);
    expect(lines.indexOf(_p02Question), greaterThan(lines.indexOf(_p01Question)));

    await _teardown(tester);
  });

  testWidgets('reaches its first question inside the 5-8s the script requires',
      (tester) async {
    await _mountChat(tester);
    final arrivals = await _play(
      tester,
      limit: const Duration(seconds: 20),
      stopWhen: (lines) => lines.contains(_p01Question),
    );

    final firstBubble = arrivals[_firstLine];
    final question = arrivals[_p01Question];
    expect(firstBubble, isNotNull);
    expect(question, isNotNull);

    // The document's headline production finding: v1 waited too long to invite
    // participation. This is the regression guard on that, and it is why
    // Odysseus is in _briskScriptCharacters — at the shared _readablePacing
    // this same script does not ask until 10.0s.
    expect(
      question!,
      inInclusiveRange(5000, 8000),
      reason: 'first question landed at ${question}ms, outside the 5-8s rule',
    );

    await _teardown(tester);
  });

  testWidgets('offers the first pause\'s quick replies before he has finished '
      'speaking', (tester) async {
    await _mountChat(tester);
    await _play(tester, limit: const Duration(seconds: 2));

    // The strip is on screen from the first frame for a scripted character, so
    // there is something to tap long before the opening turn ends.
    for (final q in _set01) {
      expect(find.text(q), findsOneWidget, reason: 'set 1 should be offered');
    }

    await _teardown(tester);
  });

  testWidgets('advances the strip to the next set at each pause',
      (tester) async {
    await _mountChat(tester);
    await _play(
      tester,
      limit: const Duration(seconds: 30),
      stopWhen: (lines) => lines.contains(_p02Question),
    );
    // Let the strip's cross-fade settle after the pause point.
    await tester.pump(const Duration(milliseconds: 600));

    for (final q in _set02) {
      expect(find.text(q), findsOneWidget, reason: 'set 2 should be offered');
    }
    for (final q in _set01) {
      expect(find.text(q), findsNothing, reason: 'set 1 should be gone');
    }

    await _teardown(tester);
  });

  testWidgets('stops the script when a quick reply is tapped, and falls back '
      'to a set that can be asked cold', (tester) async {
    await _mountChat(tester);
    await _play(
      tester,
      limit: const Duration(seconds: 20),
      stopWhen: (lines) => lines.contains(_p01Question),
    );

    await tester.tap(find.text(_set01.first));
    // _StarterPrompts holds the chosen row for 260ms before sending.
    await tester.pump(const Duration(milliseconds: 400));
    // Well past the next scripted turn's pause, had it survived.
    await tester.pump(const Duration(seconds: 20));

    // Asserted against the script's own later lines rather than a message
    // count: the tap sends, the send reaches for a worker that is not there,
    // and the resulting failure bubble is a message too. What matters is that
    // no *scripted* line arrives after she speaks.
    final lines = await _delivered();
    expect(lines, isNot(contains(_p02FirstLine)),
        reason: 'the rest of the script must never be said once she speaks');
    expect(lines, isNot(contains(_p02Question)));

    // The interrupted-script fallback. Without sets 13-16 there would be no
    // stands-alone set to move to and the strip would freeze on set 1 — v2's
    // answer-shaped replies cannot serve as their own fallback.
    final offered = _coldSafeSets.where((q) => find.text(q).evaluate().isNotEmpty);
    expect(offered, isNotEmpty,
        reason: 'strip should fall back to a cold-safe set, not freeze');

    await _teardown(tester);
  });

  testWidgets('does not replay the script into a chat that already has one',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      _historyKey: [
        jsonEncode({
          'id': 'welcome_1',
          'text': _firstLine,
          'isUser': false,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      ],
    });

    await _mountChat(tester);
    await _play(tester, limit: const Duration(seconds: 30));

    final lines = await _delivered();
    expect(lines, [_firstLine],
        reason: 'the welcome sequence only runs into an empty chat');

    await _teardown(tester);
  });
}
