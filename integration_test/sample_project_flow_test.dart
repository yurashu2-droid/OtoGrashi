import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:otogurashi/app/otogurashi_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled synthetic sample reaches a native rendered preview', (
    tester,
  ) async {
    await tester.pumpWidget(const OtogurashiApp());
    await tester.tap(find.text('聴いてみる'));

    for (var attempt = 0; attempt < 120; attempt++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('この音でつくる').evaluate().isNotEmpty) break;
      expect(find.text('準備できませんでした。もう一度お試しください。'), findsNothing);
    }

    expect(find.text('この音でつくる'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('この音でつくる'), 220);
    await tester.tap(find.text('この音でつくる'));
    for (var attempt = 0; attempt < 120; attempt++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('これで完成').evaluate().isNotEmpty) break;
    }
    expect(find.text('これで完成'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('これで完成'), 220);
    await tester.tap(find.text('これで完成'));
    await tester.pumpAndSettle();
    expect(find.text('つくれたよ'), findsOneWidget);
    expect(find.text('映り込みや会話がないか、最後に確認してください。'), findsOneWidget);
  });
}
