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
const String _firstLine = "I wasn't expecting company.";
const String _p01Question =
    'You may already have an opinion of me. What have you heard?';
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

/// [logicalSize] defaults to an iPhone 13 rather than flutter_test's 800x600.
/// _StarterPrompts thins itself out below 720 logical pixels of height, so on
/// the default surface the strip is legitimately reduced and every assertion
/// about a full set fails for a reason that has nothing to do with the script.
/// The strip's own thresholds are exercised deliberately further down.
Future<void> _mountChat(
  WidgetTester tester, {
  Size logicalSize = const Size(390, 844),
}) async {
  tester.view.physicalSize = logicalSize * 3.0;
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

/// Whether the instruction line turns green at any point in [window].
///
/// Sampled across the window rather than pumped to an exact peak: the flash is
/// two beats inside a 1.1s controller that starts ~2.7s after the set lands,
/// and timing a test to that would be flaky for no benefit.
///
/// Green is detected as "g channel above r", which holds for any point along
/// the lerp from the resting white towards the accent green and for neither
/// endpoint of the resting state.
Future<bool> _instructionEverGreen(
  WidgetTester tester, {
  Duration window = const Duration(seconds: 5),
  Duration step = const Duration(milliseconds: 50),
}) async {
  var elapsed = 0;
  while (elapsed < window.inMilliseconds) {
    await tester.pump(step);
    elapsed += step.inMilliseconds;
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      final span = text.textSpan;
      if (span is! TextSpan) continue;
      if (!span.toPlainText().contains('Choose')) continue;
      final directive = span.children?.first;
      if (directive is! TextSpan) continue;
      final c = directive.style?.color;
      if (c != null && c.g > c.r + 0.02) return true;
    }
  }
  return false;
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
    // 49, not 51: turn 1 lost two bubbles so its question lands ahead of the
// median visitor's departure rather than just behind it.
    expect(lines.length, 49, reason: 'v2 is 12 turns / 49 bubbles');
    expect(lines.first, _firstLine);
    expect(lines.last, _p12Question);
    // Every turn ends on a question to the visitor — the whole point of v2.
    expect(lines[2], _p01Question);
    expect(lines.indexOf(_p02Question), greaterThan(lines.indexOf(_p01Question)));

    await _teardown(tester);
  });

  testWidgets('asks its first question before the median visitor leaves',
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

    // This used to assert 5000-8000ms, from the v2 document's "first question
    // within 5-8 seconds". The upper bound survives. The lower bound does not,
    // and it is worth saying why rather than quietly widening the range.
    //
    // The 5s floor was written to stop the opening feeling rushed, before any
    // production data existed. The data since: across 74 chat opens, the median
    // visitor left the chat screen at 5.5s and 51% were gone before the question
    // arrived at 6.3s. A floor of 5s therefore guaranteed that roughly half the
    // audience was never asked anything — the exact failure the 5-8s rule was
    // written to prevent. Landing earlier is not rushing, it is arriving.
    //
    // The upper bound is kept as the original regression guard, and is why
    // Odysseus is in _briskScriptCharacters: at the shared _readablePacing this
    // script does not ask until 10.0s.
    expect(
      question!,
      lessThanOrEqualTo(8000),
      reason: 'first question landed at ${question}ms, later than the 8s rule',
    );
    // A floor still exists, far below the old one: the question must not land
    // before the character has introduced himself at all, or it reads as a
    // non-sequitur from a stranger.
    expect(question, greaterThan(firstBubble!));

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

  // What the strip gives up when it runs out of height. The order matters:
  // v2 bets the opening on one-tap answers, and the screens that run short are
  // mostly phones with the keyboard up — the worst possible place to hide one
  // of three replies, which is what this used to do.

  testWidgets('keeps all three replies on a short screen, dropping the hint',
      (tester) async {
    // 700 logical px: under the 720 hint threshold, over the 560 prompt one.
    await _mountChat(tester, logicalSize: const Size(390, 700));
    await _play(
      tester,
      limit: const Duration(seconds: 20),
      stopWhen: (lines) => lines.contains(_p01Question),
    );
    await tester.pump(const Duration(milliseconds: 900));

    for (final q in _set01) {
      expect(find.text(q), findsOneWidget,
          reason: 'a short screen must not cost a reply');
    }
    expect(find.byIcon(Icons.touch_app_outlined), findsNothing,
        reason: 'the hint yields first, not a prompt');

    await _teardown(tester);
  });

  testWidgets('drops the third reply only when the screen is very short',
      (tester) async {
    await _mountChat(tester, logicalSize: const Size(390, 520));
    await _play(
      tester,
      limit: const Duration(seconds: 20),
      stopWhen: (lines) => lines.contains(_p01Question),
    );
    await tester.pump(const Duration(milliseconds: 900));

    final shown = _set01.where((q) => find.text(q).evaluate().isNotEmpty);
    expect(shown.length, 2,
        reason: 'below 560 there is room for two prompts and nothing else');

    await _teardown(tester);
  });

  testWidgets('shows the hint on a full-height screen', (tester) async {
    await _mountChat(tester);
    await _play(
      tester,
      limit: const Duration(seconds: 20),
      stopWhen: (lines) => lines.contains(_p01Question),
    );
    await tester.pump(const Duration(milliseconds: 900));

    expect(find.byIcon(Icons.touch_app_outlined), findsOneWidget);
    for (final q in _set01) {
      expect(find.text(q), findsOneWidget);
    }

    await _teardown(tester);
  });

  testWidgets('calls the rows answers or questions, to match the set',
      (tester) async {
    await _mountChat(tester);
    await _play(
      tester,
      limit: const Duration(seconds: 20),
      stopWhen: (lines) => lines.contains(_p01Question),
    );
    await tester.pump(const Duration(milliseconds: 900));

    // Set 1 is answer-shaped — "The Trojan Horse, of course." — and calling
    // that a question is the wrongness this guards against.
    expect(find.textContaining('Choose your reply'), findsOneWidget,
        reason: 'the twelve scripted sets are answers');

    // Tapping interrupts the script and drops to a cold-safe set, every entry
    // of which really is a question.
    await tester.tap(find.text(_set01.first));
    await tester.pump(const Duration(milliseconds: 400));
    // The same settle the interruption test uses. The fallback set does not
    // land straight after the send, and a shorter pump reads as wrong copy
    // rather than as an early look.
    await tester.pump(const Duration(seconds: 20));

    expect(find.byIcon(Icons.touch_app_outlined), findsOneWidget,
        reason: 'the strip should survive the send');
    expect(find.textContaining('Choose a question'), findsOneWidget,
        reason: 'the cold-safe fallback sets are questions');

    await _teardown(tester);
  });

  testWidgets('stops teaching the strip once the visitor has tapped once',
      (tester) async {
    await _mountChat(tester);

    // Set 1 is on screen from the first frame, so the first flash lands around
    // 3.6s — inside this window, and before P01's pause advances the set.
    expect(await _instructionEverGreen(tester), isTrue,
        reason: 'the strip has to teach itself before the first tap');

    await tester.tap(find.text(_set01.first));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
        await _instructionEverGreen(tester,
            window: const Duration(seconds: 6)),
        isFalse,
        reason: 'once they have sent something, the lesson is over for good');

    await _teardown(tester);
  });
}
