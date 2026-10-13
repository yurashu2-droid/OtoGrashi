import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/features/create/performance_controls.dart';

void main() {
  testWidgets(
    'all performance modes and 30 seconds are selectable on a narrow phone',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var mode = PerformanceMode.natural;
      var seconds = 15;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: PerformanceControls(
                  mode: mode,
                  seconds: seconds,
                  onMode: (v) => setState(() => mode = v),
                  onDuration: (v) => setState(() => seconds = v),
                ),
              ),
            ),
          ),
        ),
      );
      // the two lengths are small pills on one line, not full-width bars
      final short = tester.getRect(find.text('15秒'));
      final long = tester.getRect(find.text('30秒・展開あり'));
      expect(short.center.dy, long.center.dy);
      expect(long.left, greaterThan(short.right));
      // the four forms people reach for come first
      expect(find.byType(ChoiceChip), findsNWidgets(4));
      await tester.ensureVisible(find.text('MAD（おすすめ）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MAD（おすすめ）'));
      await tester.pumpAndSettle();
      expect(mode, PerformanceMode.mad);
      // the rest open from the end of the same sliding row
      await tester.ensureVisible(find.text('ほかのつくり方'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ほかのつくり方'));
      await tester.pumpAndSettle();
      expect(find.text('ほかのつくり方'), findsNothing);
      expect(find.byType(ChoiceChip), findsNWidgets(10));
      await tester.ensureVisible(find.text('声レコード'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('声レコード'));
      await tester.pumpAndSettle();
      expect(mode, PerformanceMode.vinyl);
      await tester.ensureVisible(find.text('30秒・展開あり'));
      await tester.tap(find.text('30秒・展開あり'));
      await tester.pumpAndSettle();
      expect(seconds, 30);
      expect(tester.takeException(), isNull);
    },
  );
}
