import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/design/rolling_tab_bar.dart';
import 'package:otogurashi/design/tokens.dart';

void main() {
  testWidgets('tabs report taps and the ball rolls to the new tab', (
    tester,
  ) async {
    var selected = RollingTab.home;
    final picked = <RollingTab>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOtogurashiTheme(),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            bottomNavigationBar: RollingTabBar(
              selected: selected,
              onSelected: (tab) {
                picked.add(tab);
                setState(() => selected = tab);
              },
            ),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('ホーム'), findsOneWidget);
    expect(find.bySemanticsLabel('録る'), findsOneWidget);
    expect(find.bySemanticsLabel('曲'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('曲'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('録る'));
    await tester.pumpAndSettle();

    expect(picked, [RollingTab.songs, RollingTab.capture]);
    expect(tester.takeException(), isNull);
  });
}
