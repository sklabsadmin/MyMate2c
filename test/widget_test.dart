import 'package:flutter_test/flutter_test.dart';
import 'package:mythos_live/src/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ProviderScope(child: AIApp()));
    // Expect no crash
  });
}
