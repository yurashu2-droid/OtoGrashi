import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/app/otogurashi_app.dart';

void main() {
  testWidgets('first launch offers a sample and personal recording', (
    tester,
  ) async {
    await tester.pumpWidget(const OtogurashiApp());

    expect(find.text('聴いてみる'), findsOneWidget);
    expect(find.text('自分の音でつくる'), findsOneWidget);
  });
}
