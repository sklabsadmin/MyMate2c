// Dumps Odysseus's scripted opening as a timeline: when each bubble lands, and
// which quick-reply set is on the strip at that moment.
//
// Not an assertion test — it prints a table for tool/beat_map.mjs to turn into
// the tick map the admin analysis needs. It drives the real ChatScreen for the
// same reason the behaviour tests do: the timing is an interaction between the
// script data, the pacing constants and the player loop, and a reimplementation
// of that arithmetic somewhere else would be a second thing to keep in sync and
// the first thing to drift.
//
// Timing comes from flutter_test's virtual clock, so these are exact. A real
// browser is not: a backgrounded tab is throttled to 1Hz and quantises every
// delay to a whole second, which moves the real numbers later, never earlier.
// Read the output as the floor.
//
//   flutter test test/odysseus_beat_map_dump.dart --plain-name dump
//
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

/// Every quick reply Odysseus can offer, flattened. Used to read the strip's
/// current set out of the widget tree by looking for which of them is mounted.
const List<List<String>> _sets = [
  ['The Trojan Horse, of course.', 'Mostly your adventures.', 'I know about you and Penelope.'],
  ['The terrible decision.', 'Tell me about the island.', 'Definitely the monster.'],
  ["Yes — definitely.", "I'm usually more careful than that.", "I'll tell you if you tell me yours first."],
];

Future<List<String>> _delivered() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_historyKey) ?? const [];
  return raw
      .map((s) => jsonDecode(s) as Map<String, dynamic>)
      .where((m) => m['isUser'] != true && m['isSystem'] != true)
      .map((m) => m['text'] as String)
      .toList();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(
      envString: 'WORKER_URL=http://localhost\nAPP_SECRET=test',
    );
  });

  testWidgets('dump', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532); // iPhone 13
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    // Answer the 1.7.1 entry gate before timing anything. Nothing plays until
    // it is tapped, so a dump that skipped it recorded an empty script and the
    // beat map failed outright on the missing first line — which is the right
    // failure: the timings it used to print described a screen that performs at
    // people unasked, and that screen no longer exists.
    //
    // Everything below is therefore measured from the tap, not from mount. That
    // is the honest zero now: the visitor asked for this.
    if (AppConfig.requireTapToEnter) {
      final enter = find.text('Tap to Talk');
      expect(enter, findsOneWidget,
          reason: 'the entry card should be up on a fresh conversation');
      await tester.tap(enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
    }

    // 100ms steps to 40s: finer than the 500ms tick cadence being mapped, and
    // past the 28s tick cap with room to spare.
    const stepMs = 100;
    const limitMs = 40000;
    final arrivals = <String, int>{};
    final setAt = <int, int>{}; // elapsed ms -> index of the set on the strip

    var elapsed = 0;
    while (elapsed < limitMs) {
      await tester.pump(const Duration(milliseconds: stepMs));
      elapsed += stepMs;
      for (final line in await _delivered()) {
        arrivals.putIfAbsent(line, () => elapsed);
      }
      for (var s = 0; s < _sets.length; s++) {
        if (find.text(_sets[s].first).evaluate().isNotEmpty) {
          setAt[elapsed] = s;
          break;
        }
      }
    }

    final ordered = arrivals.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    // Machine-readable, fenced so the runner's own output can be stripped.
    print('BEATMAP_JSON_START');
    print(jsonEncode({
      'stepMs': stepMs,
      'lines': [
        for (final e in ordered) {'atMs': e.value, 'text': e.key},
      ],
      'strip': [
        for (final e in (setAt.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key))))
          {'atMs': e.key, 'set': e.value},
      ],
    }));
    print('BEATMAP_JSON_END');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 4));
  });
}
