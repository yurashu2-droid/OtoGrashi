import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/app/otogurashi_app.dart';

void main() {
  testWidgets('first launch starts with personal recording', (tester) async {
    await tester.pumpWidget(const OtogurashiApp());

    expect(find.text('聴いてみる'), findsNothing);
    expect(find.text('自分の音でつくる'), findsOneWidget);
    final semantics = tester.getSemantics(find.bySemanticsLabel('自分の音でつくる'));
    final data = semantics.getSemanticsData();
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(
      find.descendant(
        of: find.bySemanticsLabel('自分の音でつくる'),
        matching: find.byType(FilledButton),
      ),
      findsNothing,
    );
  });
}
