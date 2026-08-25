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
import 'package:ai_boyfriend_chat/src/features/wallet/coin_wallet.dart';
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
// The card's button is gated on coins being live: 'Tap to Talk' in a dark
// build (the default in tests, which enable no wallet), 'Tap to Claim Coins'
// only when a test seeds an enabled wallet.
const String _enterButton = 'Tap to Talk';
const String _enterButtonCoins = 'Tap to Claim Coins';
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
  _giftSheetTests();

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
  testWidgets('the claim screen pays out once, and holds the story until it is collected',
      (tester) async {
    // The button says "Tap to Claim Coins", so the tap owes the visitor a
    // payout — and on a campaign arrival this screen is the only place it can
    // be made: the dashboard, whose listener normally toasts a grant, is never
    // built. The wallet is seeded the way an app-load sync leaves a fresh
    // visitor, with the grants still pending.
    tester.view.physicalSize = const Size(390, 844) * 3.0;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coinWalletProvider.overrideWith(_SeededWalletNotifier.new),
        ],
        child: const MaterialApp(
          home: ChatScreen(scenario: _scenario, characterId: 'odysseus'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byKey(const ValueKey('coin_claim_surface')), findsNothing,
        reason: 'nothing is claimed before the tap that claims it');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    await tester.tap(find.text(_enterButtonCoins));
    await tester.pump();
    expect(find.byKey(const ValueKey('coin_claim_surface')), findsOneWidget,
        reason: 'the screen is up on the very frame the card goes away');

    // The purse fills over ~2.2s and the figure counts with it, so the total
    // is only true once it has finished — asserting it on the first frame
    // reads "+0" and would be pinning the animation's start, not the payout.
    await tester.pump(const Duration(milliseconds: 2400));

    // What landed, itemised, with the total the headline promises.
    expect(find.text('+100'), findsOneWidget,
        reason: 'the headline is the sum the entry card promised');
    expect(find.text('Welcome gift'), findsOneWidget);
    expect(find.text('Dawn offering'), findsOneWidget);
    expect(container.read(coinWalletProvider).value?.lastGranted, isEmpty,
        reason: 'consumed at the tap — a rebuild cannot pay it a second time');

    // Two minutes of virtual time with the claim up. The same rule the entry
    // card is built on: not one line may be said to a screen nobody is
    // looking at. Without the deferral in _enterChat the whole opening plays
    // out behind this and is gone by the time it is dismissed.
    await _play(tester, limit: const Duration(seconds: 120));
    expect(await _delivered(), isEmpty,
        reason: 'the opening must wait behind the claim screen');
    expect(find.byKey(const ValueKey('coin_claim_surface')), findsOneWidget,
        reason: 'and nothing dismisses it but the button');

    // Collecting resumes exactly what the entry tap deferred.
    await tester.tap(find.text('Collect and begin'));
    await tester.pump();
    expect(find.byKey(const ValueKey('coin_claim_surface')), findsNothing);
    await _play(tester, limit: const Duration(seconds: 30));
    expect(await _delivered(), isNotEmpty,
        reason: 'the conversation begins when the coins are collected');

    await _teardown(tester);
  });

  testWidgets('the claim screen fits the shortest viewport that reaches us',
      (tester) async {
    // 360x560 is the small end of the in-app browser band the entry card
    // already has a #fold=below flag for. This screen is one Column of fixed
    // content, so it cannot scroll out of trouble the way that card can: if
    // it overflows, the button goes off the bottom and the visitor is stuck
    // on a screen whose only exit is the one control they cannot reach.
    tester.view.physicalSize = const Size(360, 560) * 3.0;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coinWalletProvider.overrideWith(_SeededWalletNotifier.new),
        ],
        child: const MaterialApp(
          home: ChatScreen(scenario: _scenario, characterId: 'odysseus'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.tap(find.text(_enterButtonCoins), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('coin_claim_surface')), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'a RenderFlex overflow here is a screen with no way out');

    // The button is not merely in the tree — it is on the glass, above the
    // bottom edge, which is the part an overflow would break.
    final button = tester.getRect(find.text('Collect and begin'));
    expect(button.bottom, lessThanOrEqualTo(560));
    expect(button.top, greaterThanOrEqualTo(0));

    await tester.tap(find.text('Collect and begin'));
    await tester.pump();
    expect(find.byKey(const ValueKey('coin_claim_surface')), findsNothing);

    await _teardown(tester);
  });

  testWidgets('a visitor with nothing to claim goes straight into the story',
      (tester) async {
    // The returning visitor, and the reason takeGrants is consume-once: a
    // claim screen showing "+0" would be worse than no screen at all.
    await _mountChat(tester);

    expect(find.byKey(const ValueKey('coin_claim_surface')), findsNothing);
    await _play(tester, limit: const Duration(seconds: 30));
    expect(await _delivered(), isNotEmpty,
        reason: 'nothing should have been deferred');

    await _teardown(tester);
  });

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

  testWidgets('switching character in place resets the card and the reply '
      'count', (tester) async {
    // The chat branch keeps this State alive in the shell's indexed stack, so
    // opening a second character arrives through didUpdateWidget on the SAME
    // State. Its "full reset" used to clear three fields and leave the rest
    // describing the character just left. Two of the survivors are asserted
    // here: the entry card (still up over the next character's restored chat)
    // and the reply count (a login gate firing on a fresh character's first
    // message).
    //
    // Hercules has history the visitor once spoke in and a spent free-reply
    // allowance; Odysseus is fresh. Same element, scenario swapped.
    const hercKey = 'chat_history_Hercules (Son of Zeus)';
    SharedPreferences.setMockInitialValues({
      hercKey: [
        jsonEncode({
          'id': 'u1',
          'text': 'Tell me about Omphale.',
          'isUser': true,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      ],
      // The stored per-character count is keyed on the character; the bug was
      // that the in-memory copy did not follow it across a switch.
      'reply_count_v1_hercules': 20,
    });
    tester.view.physicalSize = const Size(390, 844) * 3.0;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget build(String scenario, String id) => ProviderScope(
          child: MaterialApp(
            home: ChatScreen(scenario: scenario, characterId: id),
          ),
        );

    // Start on Odysseus, fresh: card up.
    await tester.pumpWidget(build(_scenario, 'odysseus'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text(_enterButton), findsOneWidget);

    // Switch to Hercules, who has been spoken to: no card, and it must not
    // still be Odysseus's card sitting over his conversation.
    await tester.pumpWidget(build('Hercules (Son of Zeus)', 'hercules'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(_enterButton), findsNothing,
        reason: "the previous character's card must not survive the switch");

    // And back to Odysseus, fresh again: the card is owed again, and nothing
    // Hercules's history put on screen may leak into it.
    await tester.pumpWidget(build(_scenario, 'odysseus'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(_enterButton), findsOneWidget,
        reason: 'a fresh character after a spoken one gets its card back');
    expect(find.text('Tell me about Omphale.'), findsNothing,
        reason: "the last character's messages must be cleared");

    await _teardown(tester);
  });

  testWidgets("Hercules's strip falls back to askable questions once he is "
      'interrupted', (tester) async {
    // Every set his document specifies is an answer to the line before it, so
    // none stands alone — and once a visitor typed during his script the
    // cold-safe fallback was empty and the strip froze on e.g. "The charm,
    // obviously." for the rest of the conversation. His two question-form
    // sets past the script are what it falls back to now.
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
    // Into turn 2, then interrupt him by typing and sending. The strip holds
    // its set through the send on purpose and moves when the reply lands
    // (_setQuickReplyIndex(_quickReplyIndex + 1) after the bubbles), and that
    // move is where the cold-safe filter runs — so the send has to complete.
    // The worker is not there, so what lands is the failure bubble; it is a
    // reply for this purpose.
    await tester.pump(const Duration(seconds: 3));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_upward));
    await tester.pump();
    await tester.pump(const Duration(seconds: 12));

    // The strip must now offer a set that can be asked cold, not the opening
    // set's answers to a question about what makes a man interesting.
    expect(find.text('He makes me laugh.'), findsNothing,
        reason: 'the opening set is an answer to a line he no longer says');
    expect(
      find.text("What's the story with you and Queen Omphale?").evaluate().isNotEmpty ||
          find.text('Which of the Twelve Labors was the hardest?').evaluate().isNotEmpty,
      isTrue,
      reason: 'a cold-safe question set should be on offer',
    );

    await _teardown(tester);
  });

  testWidgets('keeps the message field out of focus traversal while up',
      (tester) async {
    // The card is opaque and swallows taps, but Tab on desktop web walked past
    // it to the field, and a keystroke there logged input_typed for a visit
    // whose card was never tapped. ExcludeFocus now takes the chat out of
    // traversal while the card is up, and puts it back the moment it drops.
    await _mountChat(tester, enterChat: false);
    expect(find.text(_enterButton), findsOneWidget);

    // Whichever node the field would receive focus through, it must not be
    // reachable by traversal.
    final fieldElement = tester.element(find.byType(TextField));
    final scope = FocusScope.of(fieldElement);
    final reachable = scope.traversalDescendants
        .where((n) => n.context != null && n.context!.widget is EditableText)
        .toList();
    expect(reachable, isEmpty,
        reason: 'the field must not be reachable by Tab while the card is up');

    // Tap through, and it comes back. Asserted on the field's own node rather
    // than a second traversalDescendants read: that list is rebuilt lazily,
    // and reading it again in the same frame returns the stale exclusion.
    // canRequestFocus is what a Tab press actually consults.
    await tester.tap(find.text(_enterButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    // The TextField's own node, not Focus.of(EditableText): the latter is an
    // inner node EditableText wraps, and ExcludeFocus does not restore its
    // flag on the way out — a probe showed the field's node returning to
    // true at +1ms and typing working, while the inner one stayed false.
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.focusNode?.canRequestFocus, isTrue,
        reason: 'once entered, the field is focusable again');

    await _teardown(tester);
  });

  testWidgets('parses a title that contains a parenthesis the same way '
      'everywhere', (tester) async {
    // Three parsers of the scenario string agreed on every roster entry and
    // would have disagreed on this one. Now there is one, and the entry card
    // and the profile header read from it — asserted through the two surfaces
    // that used to have their own.
    tester.view.physicalSize = const Size(390, 844) * 3.0;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ChatScreen(
            scenario: 'Zeus (King (of the Gods))',
            characterId: 'zeus',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // Name is everything before the FIRST " (", title everything inside up to
    // the LAST ")". The card shows both; the app bar shows the raw scenario.
    expect(find.text('Zeus'), findsWidgets);
    expect(find.text('King (of the Gods)'), findsOneWidget,
        reason: 'the inner parenthesis belongs to the title, not the name');

    await _teardown(tester);
  });

  testWidgets('shows every part of the card as it actually ships',
      (tester) async {
    // The one test that asserts the card's parts by name, with an image — the
    // rest of the suite mounts without one, so the portrait and the profile
    // hint were rendered in no test that checked for them, and a regression
    // hiding either would have kept everything green. Written alongside the
    // extraction into _EntryGate, so it also proves the extraction moved
    // nothing.
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
            characterImage: 'assets/images/avatar_hercules_real.jpg',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // Identity block: portrait, name, title, tagline.
    final portrait = find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle &&
        (w.decoration as BoxDecoration).image != null &&
        w.constraints?.maxWidth == 190);
    expect(portrait, findsOneWidget, reason: 'the 190px circular portrait');
    expect(find.text('Hercules'), findsWidgets);
    expect(find.text('Son of Zeus'), findsWidgets);
    expect(find.text('Strongest Mortal and Hero of Olympus.'), findsOneWidget,
        reason: 'the tagline, which only Hercules currently has');

    // The profile hint — shown only when there is a profile AND an image,
    // which is why no other test ever rendered it.
    expect(find.text('Tap the photo or name for the full profile'),
        findsOneWidget);
    expect(find.byIcon(Icons.touch_app_outlined), findsWidgets);

    // No wallet is enabled here, so the card is in its dark-build form: the
    // original per-character invitation and 'Tap to Talk'. The coins copy is
    // covered by the claim-payout test, which seeds an enabled wallet.
    expect(
      find.text('Hercules would like to talk to you,\n'
          'and understand your journey'),
      findsOneWidget,
    );
    expect(find.text(_enterButton), findsOneWidget);

    // The reduce-motion branch of the button is deliberately not asserted
    // here: MaterialApp's View rebuilds MediaQuery from the platform
    // dispatcher, and driving that flag through the test harness turned out
    // to need more investigation than a presence test should carry.

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


/// A wallet the way an app-load sync leaves it for a fresh visitor: enabled,
/// funded, with the welcome and dawn grants still waiting for their toast.
/// No network — overriding build() replaces the real notifier's refresh.
/// A funded wallet with the catalogue priced, for the gift-sheet tests. The
/// pendant list is what makes a row read "Worn", so it is the knob these
/// tests turn.
class _RichWalletNotifier extends CoinWalletNotifier {
  static List<String> pendants = const [];

  @override
  Future<CoinWalletState?> build() async => CoinWalletState(
        enabled: true,
        balance: 600,
        tributePrices: const {'roses': 50, 'ambrosia': 150, 'pendant': 500},
        pendants: pendants,
      );

  // A funded, returning wallet has nothing left to claim, so the tap goes
  // straight into the story.
  @override
  Future<List<CoinGrant>> claim() async => const [];
}

/// A fresh visitor: enabled, but empty until they TAP. build() is the
/// read-only app-load state (balance 0, no grants); claim() is what the tap
/// triggers, and the only place the 100 is minted — mirroring the real
/// grant-on-claim flow.
class _SeededWalletNotifier extends CoinWalletNotifier {
  @override
  Future<CoinWalletState?> build() async =>
      const CoinWalletState(enabled: true, balance: 0);

  @override
  Future<List<CoinGrant>> claim() async {
    const granted = [CoinGrant('welcome', 80), CoinGrant('daily', 20)];
    // Consumed at the tap: state carries the new balance but no pending
    // grants, so a rebuild cannot pay it a second time.
    state = const AsyncData(CoinWalletState(enabled: true, balance: 100));
    return granted;
  }
}


void _giftSheetTests() {
  Future<void> _mountFunded(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3.0;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [coinWalletProvider.overrideWith(_RichWalletNotifier.new)],
        child: const MaterialApp(
          home: ChatScreen(scenario: _scenario, characterId: 'odysseus'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    // No pending grants on this wallet, so the entry tap goes straight in.
    await tester.tap(find.text(_enterButtonCoins));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('the gift button sits in the strip and opens the catalogue',
      (tester) async {
    // Before this button existed the only way to spend was the coin chip in
    // the app bar — findable if you already knew, invisible if you did not.
    _RichWalletNotifier.pendants = const [];
    await _mountFunded(tester);

    expect(find.text('Gift'), findsOneWidget,
        reason: 'the way in has to be in the conversation, not just the bar');

    await tester.tap(find.text('Gift'));
    // Explicit pumps, not pumpAndSettle: the composer's glow never stops
    // animating, so settling never happens on this screen.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The catalogue, at the server's prices — the client never invents one.
    expect(find.text('Roses'), findsOneWidget);
    expect(find.text('Ambrosia'), findsOneWidget);
    expect(find.text('Pendant'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);
    expect(find.text('500'), findsOneWidget);
    expect(find.text('Worn'), findsNothing);

    await _teardown(tester);
  });

  testWidgets('a given gift is the picture alone — the words go to the model only',
      (tester) async {
    // Two things have to be true at once, and they pull in opposite
    // directions: the stage direction must still travel (it is what the
    // character is answering, and _loadHistory rebuilds the model's view of
    // the conversation out of these stored messages), but it must not be
    // drawn. Deleting the text to hide it would silently cost the model the
    // fact that anything was given.
    _RichWalletNotifier.pendants = const [];
    await _mountFunded(tester);

    await tester.tap(find.text('Gift'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Roses'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.image(const AssetImage('assets/images/gift_roses.png')),
        findsWidgets, reason: 'the roses themselves are the message');
    expect(find.textContaining('gives roses'), findsNothing,
        reason: 'the stage direction is for the model, not the screen');

    // …and it is still on the message, which is what the model and a reopened
    // conversation both read.
    final stored = await SharedPreferences.getInstance();
    final raw = stored.getStringList(_historyKey) ?? const [];
    final gifts = raw
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .where((m) => m['giftAsset'] != null)
        .toList();
    expect(gifts, hasLength(1));
    expect(gifts.single['text'], contains('gives roses'));
    expect(gifts.single['giftAsset'], 'assets/images/gift_roses.png');

    await _teardown(tester);
  });

  testWidgets('a pendant already given reads Worn, and cannot be bought again',
      (tester) async {
    // 500 coins is a lot to spend twice on the same neck.
    _RichWalletNotifier.pendants = const ['odysseus'];
    await _mountFunded(tester);

    await tester.tap(find.text('Gift'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Worn'), findsOneWidget);
    expect(find.text('500'), findsNothing,
        reason: 'a worn pendant shows no price, because it has no price left');
    expect(find.text('Worn since you gave it.'), findsOneWidget);
    // The other two are unaffected — they are consumable.
    expect(find.text('50'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);

    _RichWalletNotifier.pendants = const [];
    await _teardown(tester);
  });
}
