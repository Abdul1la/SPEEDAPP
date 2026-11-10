import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/services/alert_engine.dart';
import 'package:new_project/theme/app_theme.dart';
import 'package:new_project/widgets/hud.dart';
import 'package:new_project/widgets/point_editor.dart';

/// A small phone (320 wide) with big system text, the hardest case.
Widget _phone(Widget child, {double width = 296}) => MaterialApp(
  theme: buildAppTheme(),
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(320, 640),
      textScaler: TextScaler.linear(1.3),
    ),
    child: Scaffold(
      body: Center(
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

void main() {
  const camera = SpeedPoint(
    id: 'c',
    type: PointType.camera,
    lat: 0,
    lng: 0,
    speedLimit: 120,
  );
  const bump = SpeedPoint(id: 'b', type: PointType.bump, lat: 0, lng: 0);

  testWidgets('banner fits a small phone with large text', (tester) async {
    for (final alert in const [
      ActiveAlert(point: camera, distance: 1234, overLimit: false),
      ActiveAlert(point: camera, distance: 87, overLimit: true),
      ActiveAlert(point: bump, distance: 250, overLimit: false),
    ]) {
      await tester.pumpWidget(
        _phone(WarningBanner(key: UniqueKey(), alert: alert, zone: 500)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    }
    expect(find.text('250 m'), findsOneWidget);
    expect(find.text('Speed bump'), findsOneWidget);
  });

  testWidgets('over the limit says Slow down and shows the sign', (
    tester,
  ) async {
    await tester.pumpWidget(
      _phone(
        const WarningBanner(
          alert: ActiveAlert(point: camera, distance: 287, overLimit: true),
          zone: 500,
        ),
      ),
    );
    expect(find.text('290 m'), findsOneWidget);
    expect(find.text('Slow down'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
    // The pulse animation runs; stop it so the test can finish.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('speed gauge shows rounded speed', (tester) async {
    await tester.pumpWidget(
      _phone(
        const Center(child: SpeedGauge(kmh: 87.6, limit: 80, overLimit: true)),
      ),
    );
    expect(find.text('88'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compass picker selects a direction and both ways', (
    tester,
  ) async {
    double? value = 0;
    await tester.pumpWidget(
      _phone(
        StatefulBuilder(
          builder: (context, setState) => CompassPicker(
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );
    await tester.tap(find.text('E'));
    await tester.pumpAndSettle();
    expect(value, 90);
    expect(find.text('E 90°'), findsOneWidget);

    await tester.tap(find.text('E 90°'));
    await tester.pumpAndSettle();
    expect(value, isNull);
    expect(find.text('Both ways'), findsOneWidget);
  });

  testWidgets('dark theme: banner and gauge render without errors', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: const Scaffold(
          body: Column(
            children: [
              WarningBanner(
                alert: ActiveAlert(
                  point: camera,
                  distance: 140,
                  overLimit: false,
                ),
                zone: 500,
              ),
              SpeedGauge(kmh: 76, limit: 80),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Speed camera'), findsOneWidget);
    expect(find.text('76'), findsOneWidget);
  });

  test('distance formatting', () {
    expect(formatDistance(287), '290 m');
    expect(formatDistance(1234), '1.2 km');
    expect(formatDistance(15400), '15 km');
  });
}
