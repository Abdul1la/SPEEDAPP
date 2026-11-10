import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/theme/app_theme.dart';
import 'package:new_project/widgets/hud.dart';

Widget gauge(double kmh) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(
    body: Center(child: SpeedGauge(kmh: kmh, limit: 80)),
  ),
);

void main() {
  testWidgets('the number is the GPS speed at once (it never lags)', (
    tester,
  ) async {
    await tester.pumpWidget(gauge(50));
    await tester.pumpAndSettle();
    expect(find.text('50'), findsOneWidget);

    // A new GPS reading: the very next frame shows it.
    await tester.pumpWidget(gauge(87.4));
    await tester.pump();
    expect(find.text('87'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('87'), findsOneWidget);
  });
}
