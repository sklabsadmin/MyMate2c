import 'package:flutter_test/flutter_test.dart';
import 'package:ai_boyfriend_chat/src/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ProviderScope(child: AIApp(onboardingCompleted: true)));
    // Expect no crash
  });
}
