// SeenDetector — does a bubble get reported as seen exactly when it was.
//
// Written after a preview run showed roughly half of a 51-bubble opening
// rendered but never sighted, in a scattered pattern that no amount of watching
// the screen could explain. The failures here are timing, and timing is what a
// widget test can hold still.
//
// The two claims that matter, and they pull against each other:
//   * every bubble the visitor actually looked at is reported, even if the list
//     was moving at the time — a miss reads as a delivery failure, which is the
//     one conclusion this whole feature exists to support or rule out
//   * nothing else is reported: not a bubble below the fold, not one flicked
//     past, not one drawn into a hidden tab

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_boyfriend_chat/src/core/presentation/seen_detector.dart';

const double _itemHeight = 100;
const double _viewportHeight = 300;

/// Longer than SeenDetector's own dwell, so "pump past the dwell" is one call
/// and does not silently become a no-op if the dwell is ever retuned.
const Duration _pastDwell = Duration(milliseconds: 400);

/// A scrolling list of fixed-height bubbles, three of which fit on screen.
Widget _harness({
  required ScrollController controller,
  required Listenable revalidate,
  required bool Function() visible,
  required void Function(String) onSeen,
  int count = 12,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          height: _viewportHeight,
          child: ListView.builder(
            controller: controller,
            itemCount: count,
            itemBuilder: (context, index) => SeenDetector(
              bubbleId: 'b$index',
              revalidate: revalidate,
              isSurfaceVisible: visible,
              onSeen: onSeen,
              child: SizedBox(height: _itemHeight, child: Text('bubble $index')),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late ScrollController controller;
  late ValueNotifier<int> surface;
  late Listenable revalidate;
  late List<String> seen;
  late bool surfaceVisible;

  setUp(() {
    controller = ScrollController();
    surface = ValueNotifier<int>(0);
    revalidate = Listenable.merge([controller, surface]);
    seen = <String>[];
    surfaceVisible = true;
  });

  tearDown(() {
    controller.dispose();
    surface.dispose();
  });

  Future<void> mount(WidgetTester tester, {int count = 12}) {
    return tester.pumpWidget(_harness(
      controller: controller,
      revalidate: revalidate,
      visible: () => surfaceVisible,
      onSeen: seen.add,
      count: count,
    ));
  }

  testWidgets('reports the bubbles on screen and nothing below the fold',
      (tester) async {
    await mount(tester);
    await tester.pump(_pastDwell);

    // Three fit in a 300px viewport. b3 is built (ListView builds a little
    // beyond the fold) but has never been visible.
    expect(seen, ['b0', 'b1', 'b2']);
  });

  testWidgets('reports nothing while the surface is not frontmost',
      (tester) async {
    surfaceVisible = false;
    await mount(tester);
    await tester.pump(_pastDwell);

    expect(seen, isEmpty);
  });

  testWidgets('reports on-screen bubbles once the surface comes back',
      (tester) async {
    surfaceVisible = false;
    await mount(tester);
    await tester.pump(_pastDwell);
    expect(seen, isEmpty);

    // The tab came back — exactly what didChangeAppLifecycleState does.
    surfaceVisible = true;
    surface.value++;
    await tester.pump();
    await tester.pump(_pastDwell);

    expect(seen, ['b0', 'b1', 'b2']);
  });

  testWidgets('reports a bubble scrolled into view', (tester) async {
    await mount(tester);
    await tester.pump(_pastDwell);
    expect(seen, ['b0', 'b1', 'b2']);

    controller.jumpTo(_itemHeight * 5);
    await tester.pump();
    await tester.pump(_pastDwell);

    expect(seen, containsAll(<String>['b5', 'b6', 'b7']));
  });

  testWidgets('reports each bubble once, however much the list moves',
      (tester) async {
    await mount(tester);
    await tester.pump(_pastDwell);

    for (var offset = 0.0; offset <= _itemHeight * 5; offset += _itemHeight) {
      controller.jumpTo(offset);
      await tester.pump();
      await tester.pump(_pastDwell);
    }

    expect(seen.toSet().length, seen.length, reason: 'a bubble was reported twice');
  });

  testWidgets('does not report a bubble flicked past', (tester) async {
    await mount(tester);

    // Straight to the end without ever holding still: nothing in between was
    // read, and counting it would make a fling look like attention.
    controller.jumpTo(_itemHeight * 9);
    await tester.pump();
    await tester.pump(_pastDwell);

    expect(seen, isNot(contains('b4')));
    expect(seen, isNot(contains('b5')));
  });

  // The regression. A new bubble arriving scrolls the list, so the dwell for a
  // bubble already on screen routinely elapses while the viewport is moving. If
  // that is treated as "not seen" and never revisited, the bubble is lost even
  // though it sat in front of the visitor the whole time — and it is lost from
  // the middle of a run, which reads exactly like a delivery fault.
  testWidgets('reports a bubble whose dwell elapsed while the list moved',
      (tester) async {
    await mount(tester);

    // Part-way through b0's dwell, shift the list so b0 is briefly outside the
    // measured band, then settle with it visible again.
    await tester.pump(const Duration(milliseconds: 150));
    controller.jumpTo(_itemHeight * 0.9);
    await tester.pump(const Duration(milliseconds: 200));
    controller.jumpTo(0);
    await tester.pump();
    await tester.pump(_pastDwell);

    expect(seen, contains('b0'),
        reason: 'a bubble on screen throughout was never reported');
  });

  testWidgets('keeps reporting later bubbles after an earlier dwell missed',
      (tester) async {
    await mount(tester);

    // Same disturbance, then carry on down the list. The bug this guards
    // against was scattered rather than total: some bubbles survived, which is
    // what made it look like a network problem rather than a client one.
    await tester.pump(const Duration(milliseconds: 150));
    controller.jumpTo(_itemHeight * 0.9);
    await tester.pump(const Duration(milliseconds: 200));

    for (var i = 3; i <= 8; i++) {
      controller.jumpTo(_itemHeight * i);
      await tester.pump();
      await tester.pump(_pastDwell);
    }

    expect(seen, containsAll(<String>['b3', 'b4', 'b5', 'b6', 'b7', 'b8']));
  });

  testWidgets('reports nothing for a bubble with no receipt', (tester) async {
    // Messages restored from local history have no receipt; reporting one would
    // claim an old message had just been read.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: _viewportHeight,
          child: ListView(
            controller: controller,
            children: [
              SeenDetector(
                bubbleId: null,
                revalidate: revalidate,
                isSurfaceVisible: () => surfaceVisible,
                onSeen: seen.add,
                child: const SizedBox(height: _itemHeight),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump(_pastDwell);

    expect(seen, isEmpty);
  });
}
