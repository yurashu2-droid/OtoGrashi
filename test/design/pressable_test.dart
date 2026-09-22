import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/design/pressable.dart';

void main() {
  testWidgets('exposes one tap action and cancels a dragged press', (
    tester,
  ) async {
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Pressable(
            semanticLabel: '作成する',
            onPressed: () => presses += 1,
            child: const SizedBox(width: 120, height: 56),
          ),
        ),
      ),
    );

    final semantics = tester
        .getSemantics(find.bySemanticsLabel('作成する'))
        .getSemanticsData();
    expect(semantics.hasAction(SemanticsAction.tap), isTrue);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Pressable)),
    );
    await tester.pump();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      0.97,
    );
    await gesture.moveBy(const Offset(160, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(presses, 0);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
  });
}
