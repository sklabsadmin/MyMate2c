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

import 'package:ai_boyfriend_chat/src/core/config/app_config.dart';
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

/// The entry card's button, and the title it is built from — restated here
/// rather than read from the widget for the same reason as the script lines.
const String _enterButton = 'Tap to Talk';
const String _characterTitle = 'King of Ithaca';

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
/// [enterChat] taps through 1.7.1's entry card, which otherwise holds the
/// opening back and would leave every test below looking at an empty chat.
/// Tests of the card itself pass false and drive it themselves.
///
/// Timings measured after this are still the ones that matter: the script now
/// starts at the tap, so "how long until he asks something" is counted from
/// when the visitor actually began the conversation rather than from a page
/// load they may have spent staring at a button.
Future<void> _mountChat(
  WidgetTester tester, {
  Size logicalSize = const Size(390, 844),
  bool enterChat = true,
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

  if (enterChat && AppConfig.requireTapToEnter) {
    expect(find.text(_enterButton), findsOneWidget,
        reason: 'the entry card should be up on a fresh conversation');
    await tester.tap(find.text(_enterButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
  }
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
    // The shipped defaults, restored per test so one that flips a switch
    // cannot leak into the next. The story freeze ships OFF — the entry card
    // takes the pulse on its own — so the tests for it opt in explicitly
    // rather than the suite quietly testing a configuration nobody runs.
    AppConfig.requireTapToEnter = true;
    AppConfig.requireInteractionToContinue = false;
  });

  _entryGateTests();

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

    // No entry card to tap through: this chat has history, so the visitor has
    // already been here and is not asked to come in again.
    await _mountChat(tester, enterChat: false);
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

  // The 1.7.1 interaction gate.
  //
  // These are the tests for the release's actual claim: that a visitor who does
  // nothing is served a story that does not move. Everything above tests what
  // the character says; these test what happens when nobody answers.

  testWidgets('stops after the opening turn and stays stopped', (tester) async {
    // The story freeze, which ships off — this test is what it does when on.
    AppConfig.requireInteractionToContinue = true;
    await _mountChat(tester);
    // Three minutes of virtual silence — an order of magnitude past the
    // longest thing that could resume it. The old script ran ~200s end to end
    // and the idle nudge fires at 14s.
    await _play(tester, limit: const Duration(seconds: 180));

    final lines = await _delivered();
    expect(lines, contains(_p01Question),
        reason: 'the opening turn still plays; the gate is not a mute button');
    expect(lines, isNot(contains(_p02FirstLine)),
        reason: 'turn 2 must not arrive on its own — that is the whole gate');
    expect(lines.last, _p01Question,
        reason: 'the question he asked has to be the last thing on screen, '
            'or the visitor is not looking at an unanswered question');

    await _teardown(tester);
  });

  testWidgets('does not fill its own silence with an idle nudge',
      (tester) async {
    // The story freeze, which ships off — this test is what it does when on.
    AppConfig.requireInteractionToContinue = true;
    await _mountChat(tester);
    await _play(tester, limit: const Duration(seconds: 60));

    // The nudge fires at 14s of quiet and is the one thing that could speak
    // without being answered. If it lands, a visitor who sat still has been
    // recorded as declining an offer that was not actually withheld, and the
    // release measures nothing.
    final lines = await _delivered();
    final scripted = lines.where((l) => l == _p01Question).length;
    expect(lines.length, greaterThan(1));
    expect(scripted, 1);
    expect(lines.last, _p01Question,
        reason: 'a nudge would have appended itself here');

    await _teardown(tester);
  });

  testWidgets('answering it lets the conversation move again', (tester) async {
    // The story freeze, which ships off — this test is what it does when on.
    AppConfig.requireInteractionToContinue = true;
    await _mountChat(tester);
    await _play(
      tester,
      limit: const Duration(seconds: 20),
      stopWhen: (lines) => lines.contains(_p01Question),
    );

    final before = (await _delivered()).length;
    await tester.tap(find.text(_set01.first));
    // _StarterPrompts holds the chosen row for 260ms before sending.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 20));

    // The tap sends into a worker that is not there, so what arrives is the
    // failure bubble rather than a reply — which is exactly the point being
    // asserted: the screen was frozen, and answering unfroze it. A real reply
    // needs a backend and belongs in the production test plan.
    expect((await _delivered()).length, greaterThan(before),
        reason: 'the gate must release on an answer, not merely on a timeout');

    await _teardown(tester);
  });

  testWidgets('the story freeze is not raised for a link that carries its own '
      'question', (tester) async {
    // The story freeze, which ships off — this test is what it does when on.
    AppConfig.requireInteractionToContinue = true;
    // /c/odysseus?initialMessage=… sends the visitor's question for them, so
    // there is nothing left to gate. Left ungated deliberately: gating here
    // would stand between someone and the answer they followed a link for, and
    // would put taps nobody made into the release's numerator.
    tester.view.physicalSize = const Size(390, 844) * 3.0;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ChatScreen(
            scenario: _scenario,
            characterId: 'odysseus',
            initialMessage: 'What happened when you reached Ithaca?',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await _play(tester, limit: const Duration(seconds: 60));

    // An idle nudge is the proof, and a sharper one than the script would be.
    // The opener is sent on the visitor's behalf and that abandons the script
    // exactly as a typed message does, so no later turn was ever going to
    // arrive here — with the gate or without it. What only happens with the
    // gate down is the character speaking into silence unprompted, which is
    // what _startIdleTimer does at 14s and refuses to do under the gate.
    final lines = await _delivered();
    expect(lines.any(_idlePrompts.contains), isTrue,
        reason: 'an opener arrival is not gated, so the 14s nudge still fires');

    await _teardown(tester);
  });
}

/// The 1.7.1 entry gate — the card over the chat with one button on it.

void _entryGateTests() {
  testWidgets('holds the whole conversation behind one button', (tester) async {
    await _mountChat(tester, enterChat: false);

    expect(find.text(_enterButton), findsOneWidget);
    expect(find.text(_characterTitle), findsWidgets,
        reason: 'the card has to say who is being tapped through to');

    // Two minutes of virtual time with the card up. Nothing behind it may run.
    await _play(tester, limit: const Duration(seconds: 120));

    expect(await _delivered(), isEmpty,
        reason: 'not one line may be said to a screen nobody has entered');
    expect(find.text(_enterButton), findsOneWidget,
        reason: 'and the card is still there — nothing dismisses it but a tap');

    await _teardown(tester);
  });

  testWidgets('covers the chat rather than tinting it', (tester) async {
    // Caught by looking at it, not by a test: the card shipped with a 0.25
    // middle gradient stop under a comment claiming it was opaque, and the
    // quick-reply strip, a starter row and the message box all read through
    // it. A one-button screen with four other tappable-looking things showing
    // through is not the thing being measured.
    //
    // Asserted on the gradient itself, because the obvious test does not work:
    // find.textContaining('Choose') still matches with the card up. The strip
    // is in the tree either way — occlusion is a paint concern and the element
    // tree knows nothing about it. So this reads the colours the card is
    // actually filled with and requires every one of them to be opaque.
    await _mountChat(tester, enterChat: false);
    expect(find.text(_enterButton), findsOneWidget);

    final surface = tester.widget<Container>(
      find.byKey(const ValueKey('entry_gate_surface')),
    );
    final gradient = (surface.decoration as BoxDecoration).gradient!;
    for (final c in gradient.colors) {
      expect(c.a, 1.0,
          reason: 'every stop of the card must be opaque — at 0.25 the strip, '
              'a starter row and the message box all read through it');
    }

    // And nothing behind it is reachable by a pointer, which is the other half
    // of "covers": a card you can tap through is not a gate.
    expect(find.byIcon(Icons.touch_app_outlined).hitTestable(), findsNothing,
        reason: 'the strip must not be tappable through the card');

    await _teardown(tester);
  });

  testWidgets('declares nothing to the delivery log until it is tapped',
      (tester) async {
    // The receipts claim, and the one most able to regress without anyone
    // noticing. _playOpeningScript declares every bubble of the opening up
    // front — that is what makes "intended but never drawn" measurable — so a
    // script started behind the card would file 49 intents for a visitor who
    // never arrived, quietly restoring the 9%-drawn number this release exists
    // to fix.
    await _mountChat(tester, enterChat: false);
    await _play(tester, limit: const Duration(seconds: 30));

    final prefs = await SharedPreferences.getInstance();
    // A single JSON string under this key, not a list — DeliveryLog._queueKey,
    // written with setString. 'welcome_script' is DeliveryOrigin.welcomeScript's
    // wire name.
    final queued = prefs.getString('delivery_receipt_queue_v1') ?? '';
    expect(queued, isNot(contains('welcome_script')),
        reason: 'no bubble may be declared before someone is watching');

    await _teardown(tester);
  });

  testWidgets('tapping it starts the opening', (tester) async {
    await _mountChat(tester, enterChat: false);
    expect(await _delivered(), isEmpty);

    await tester.tap(find.text(_enterButton));
    await tester.pump();
    await _play(
      tester,
      limit: const Duration(seconds: 20),
      stopWhen: (lines) => lines.contains(_p01Question),
    );

    expect(find.text(_enterButton), findsNothing,
        reason: 'the card goes when it is answered');
    expect(await _delivered(), contains(_p01Question));

    await _teardown(tester);
  });

  testWidgets('comes back when the conversation is started fresh',
      (tester) async {
    await _mountChat(tester);
    await _play(
      tester,
      limit: const Duration(seconds: 20),
      stopWhen: (lines) => lines.contains(_p01Question),
    );
    expect(find.text(_enterButton), findsNothing);

    // "Fresh conversation" from the header's overflow menu. Explicit pumps, not
    // pumpAndSettle: the strip's attention pass never stops, so nothing on this
    // screen ever settles and pumpAndSettle times out.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Fresh conversation').last);
    await tester.pump();
    // Past the storage clear and the reply-count read the reset awaits.
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(_enterButton), findsOneWidget,
        reason: 'a fresh conversation goes back to before the tap');
    // And it means it: nothing replays behind the card.
    await _play(tester, limit: const Duration(seconds: 30));
    expect(await _delivered(), isEmpty,
        reason: 'the opening must not replay into a screen nobody has entered');

    await _teardown(tester);
  });

  testWidgets('a question picked from the profile goes straight into the chat',
      (tester) async {
    // The only test that passes characterImage. The profile is unreachable
    // without one (_openProfile returns early), which is also why the card's
    // portrait and its "tap for the full profile" hint appear in no other test
    // here — they are not rendered when it is null.
    tester.view.physicalSize = const Size(390, 844) * 3.0;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ChatScreen(
            scenario: _scenario,
            characterId: 'odysseus',
            characterImage: 'assets/images/avatar_odysseus_real.jpg',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text(_enterButton), findsOneWidget);

    // Into the profile by the name, which the hint says is tappable.
    await tester.tap(find.text('Odysseus').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    const ask = "How do you love someone you can't reach?";
    expect(find.text(ask), findsOneWidget,
        reason: 'the profile should be open, showing its Ask Me About list');

    // "Ask Me About" sits below the About text, off-screen on a phone — the
    // finder matches a built widget, not a visible one, so tapping without
    // this hits empty space at y=1071 on an 844-tall screen.
    await tester.ensureVisible(find.text(ask));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text(ask));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Back in the chat, with the question sent — not back at the card. Being
    // returned to "Tap to Talk" after committing to a question is the bug this
    // guards: it reads as the app having lost the choice.
    expect(find.text(_enterButton), findsNothing,
        reason: 'the card must not stand between them and the answer');

    final prefs = await SharedPreferences.getInstance();
    final stored = (prefs.getStringList(_historyKey) ?? const [])
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .toList();
    expect(stored.where((m) => m['isUser'] == true && m['text'] == ask),
        isNotEmpty,
        reason: 'their question should have been sent');
    // And the scripted opening is not playing underneath it: the character
    // must not introduce himself to someone who has already asked him
    // something specific.
    expect(stored.where((m) => m['text'] == _firstLine), isEmpty,
        reason: 'the opening is skipped when they arrive already talking');

    await _teardown(tester);
  });

  testWidgets('holds on the first turn that asks something, not the first turn',
      (tester) async {
    // The story freeze, which ships off — this test is what it does when on.
    AppConfig.requireInteractionToContinue = true;
    // Hercules opens "Well, hello there." and does not ask anything until his
    // fourth turn. Holding on turn 1 would freeze the screen on a greeting —
    // a gate is an unanswered question, and there was no question.
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844) * 3.0;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ChatScreen(
            scenario: 'Hercules (Son of Zeus)',
            characterId: 'hercules',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.tap(find.text(_enterButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // Two virtual minutes: far past his whole 90-second script.
    var elapsed = 0;
    while (elapsed < 120000) {
      await tester.pump(const Duration(milliseconds: 50));
      elapsed += 50;
    }

    final prefs = await SharedPreferences.getInstance();
    final said = (prefs.getStringList('chat_history_Hercules (Son of Zeus)') ??
            const [])
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .where((m) => m['isUser'] != true && m['isSystem'] != true)
        .map((m) => m['text'] as String)
        .toList();

    expect(said.first, 'Well, hello there.');
    expect(said.last, 'What usually makes a man interesting to you?',
        reason: 'he must stop on the question, not before it and not after');
    expect(said, isNot(contains('Hmm.')),
        reason: 'turn 5 is past the gate and must never arrive unanswered');

    await _teardown(tester);
  });

  testWidgets('comes up over a monologue the visitor never answered, and does '
      'not replay it', (tester) async {
    // The production case, first night of 1.7.1: devices still on the 1.7.0
    // bundle auto-played the opening and saved it, so their history was not
    // empty when they updated — and a card gated on empty history never came
    // up for a visitor who had never engaged. 45 chat visits, 5 cards.
    SharedPreferences.setMockInitialValues({
      _historyKey: [
        for (final (i, line) in [_firstLine, _p01Question].indexed)
          jsonEncode({
            'id': 'welcome_old_$i',
            'text': line,
            'isUser': false,
            'timestamp': DateTime.now().toIso8601String(),
          }),
      ],
    });
    await _mountChat(tester, enterChat: false);

    expect(find.text(_enterButton), findsOneWidget,
        reason: 'never spoke here, so the card is owed whatever the history');

    await tester.tap(find.text(_enterButton));
    await tester.pump();
    await _play(tester, limit: const Duration(seconds: 30));

    // The two lines that were already there, and nothing added underneath.
    final lines = await _delivered();
    expect(lines, [_firstLine, _p01Question],
        reason: 'tapping through must not replay the opening into it');

    await _teardown(tester);
  });

  testWidgets('does not come up for a returning conversation', (tester) async {
    // Someone who has already spoken here has demonstrably entered. Asking
    // again would gate a conversation they are in the middle of, and would put
    // a second entry_shown against a visitor into the release's denominator.
    SharedPreferences.setMockInitialValues({
      _historyKey: [
        jsonEncode({
          'id': 'seed_1',
          'text': 'Tell me about Ithaca.',
          'isUser': true,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      ],
    });
    await _mountChat(tester, enterChat: false);

    expect(find.text(_enterButton), findsNothing);

    await _teardown(tester);
  });

  testWidgets('is not raised for a link that carries its own question',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3.0;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ChatScreen(
            scenario: _scenario,
            characterId: 'odysseus',
            initialMessage: 'What happened when you reached Ithaca?',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text(_enterButton), findsNothing,
        reason: 'an opener link must not be gated behind a tap');

    await _teardown(tester);
  });

  testWidgets('off switch restores the ungated open', (tester) async {
    AppConfig.requireTapToEnter = false;
    await _mountChat(tester, enterChat: false);

    expect(find.text(_enterButton), findsNothing);
    await _play(
      tester,
      limit: const Duration(seconds: 20),
      stopWhen: (lines) => lines.contains(_p01Question),
    );
    expect(await _delivered(), contains(_p01Question),
        reason: 'with the switch off the opening plays on arrival, as in 1.7.0');

    await _teardown(tester);
  });
}

/// The idle nudges, restated here for the same reason as the script lines
/// above: a test should fail and be looked at when this list is edited, not
/// quietly follow it.
const List<String> _idlePrompts = [
  "So — what's on your mind?",
  "Still there?",
  "Take your time. I'm not going anywhere.",
  "Anything you feel like talking about?",
  "You've gone quiet. That's allowed.",
  "What are you thinking?",
  "No rush. Say something whenever you're ready.",
  "Where did you get to?",
];
