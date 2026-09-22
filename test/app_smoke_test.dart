import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/app/otogurashi_app.dart';

void main() {
  testWidgets('first launch offers a sample and personal recording', (
    tester,
  ) async {
    await tester.pumpWidget(const OtogurashiApp());

    expect(find.text('聴いてみる'), findsOneWidget);
    expect(find.text('自分の音でつくる'), findsOneWidget);
    final semantics = tester.getSemantics(find.bySemanticsLabel('聴いてみる'));
    final data = semantics.getSemanticsData();
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(
      find.descendant(
        of: find.bySemanticsLabel('聴いてみる'),
        matching: find.byType(FilledButton),
      ),
      findsNothing,
    );
  });
}
