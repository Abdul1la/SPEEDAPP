import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/app_controller.dart';
import 'package:new_project/models/app_settings.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/models/warning_tone.dart';
import 'package:new_project/screens/settings_screen.dart';
import 'package:new_project/services/storage.dart';
import 'package:new_project/theme/app_theme.dart';
import 'package:new_project/widgets/point_editor.dart';

/// Keeps points and settings in memory instead of on the phone.
class _MemoryStorage extends Storage {
  List<SpeedPoint> saved = [];
  AppSettings? settings;

  @override
  Future<void> savePoints(List<SpeedPoint> points) async => saved = points;

  @override
  Future<void> saveSettings(AppSettings s) async => settings = s;
}

void _phone(WidgetTester tester, [Size size = const Size(320, 568)]) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('Settings: warning sounds and repeat count', (tester) async {
    _phone(tester);
    final storage = _MemoryStorage();
    final app = AppController(storage: storage);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: SettingsScreen(app: app),
      ),
    );
    await tester.scrollUntilVisible(find.text('Warning sounds'), 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Nothing picked yet: the built-in sounds, then the voice.
    expect(find.text('Chime + voice'), findsOneWidget);
    expect(find.text('Bump-bump + voice'), findsOneWidget);

    // Camera warning plays twice.
    final twice = find.text('2×').first;
    await tester.ensureVisible(twice);
    await tester.tap(twice);
    await tester.pumpAndSettle();
    expect(app.settings.repeatFor('camera'), 2);
    expect(storage.settings?.repeatFor('camera'), 2);
    expect(app.settings.repeatFor('bump'), 1);

    // Per-distance sounds open on tap.
    expect(find.text('At 500 m'), findsNothing);
    final perDistance = find.text('Different sound for each distance').first;
    await tester.ensureVisible(perDistance);
    await tester.tap(perDistance);
    await tester.pumpAndSettle();
    for (final d in app.settings.distancesFor(PointType.camera)) {
      expect(find.text('At $d m'), findsOneWidget);
    }
    await tester.scrollUntilVisible(find.text('"Slow down"'), 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings: choose a built-in sound, voice only, voice off', (
    tester,
  ) async {
    _phone(tester, const Size(390, 844));
    final storage = _MemoryStorage();
    final app = AppController(storage: storage);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: SettingsScreen(app: app),
      ),
    );
    await tester.scrollUntilVisible(find.text('Chime + voice'), 300);
    await tester.pumpAndSettle();

    // Cameras: pick "Radar" from the built-in sounds.
    await tester.tap(find.text('Chime + voice'));
    await tester.pumpAndSettle();
    expect(find.text('Built-in sounds'), findsOneWidget);
    expect(find.text('Two rising bells · default'), findsOneWidget);
    expect(find.text('From your phone'), findsOneWidget);
    await tester.tap(find.text('Radar'));
    await tester.pumpAndSettle();
    expect(app.settings.toneFor(PointType.camera), WarningTone.radar);
    expect(storage.settings?.toneFor(PointType.camera), WarningTone.radar);
    expect(find.text('Radar + voice'), findsOneWidget);

    // Bumps: the phone voice only.
    await tester.ensureVisible(find.text('Bump-bump + voice'));
    await tester.tap(find.text('Bump-bump + voice'));
    await tester.pumpAndSettle();
    final voiceOnly = find.text('Phone voice only');
    await tester.ensureVisible(voiceOnly);
    await tester.pumpAndSettle();
    await tester.tap(voiceOnly);
    await tester.pumpAndSettle();
    expect(app.settings.toneFor(PointType.bump), isNull);

    // No voice after the sound.
    final speak = find.text('Say the distance too');
    await tester.ensureVisible(speak);
    await tester.pumpAndSettle();
    await tester.tap(speak);
    await tester.pumpAndSettle();
    expect(app.settings.speakDistance, isFalse);
    expect(find.text('Radar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Point editor: its own repeat count is saved', (tester) async {
    _phone(tester);
    final storage = _MemoryStorage();
    final app = AppController(storage: storage);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showPointEditor(context, app, lat: 33.3, lng: 44.4),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Warning sound'));
    await tester.pumpAndSettle();
    expect(find.text('Same as all speed cameras'), findsOneWidget);
    expect(find.text('Default (1×)'), findsOneWidget);

    await tester.ensureVisible(find.text('3×'));
    await tester.tap(find.text('3×'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final p = storage.saved.single;
    expect(p.repeat, 3);
    expect(p.sound, isNull);
  });
}
