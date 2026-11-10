import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/app_controller.dart';
import 'package:new_project/models/app_settings.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/screens/settings_screen.dart';
import 'package:new_project/services/storage.dart';
import 'package:new_project/theme/app_theme.dart';

/// Keeps points and settings in memory instead of on the phone.
class _MemoryStorage extends Storage {
  List<SpeedPoint> saved = [];
  AppSettings? settings;

  @override
  Future<void> savePoints(List<SpeedPoint> points) async => saved = points;

  @override
  Future<void> saveSettings(AppSettings s) async => settings = s;
}

void _screen(WidgetTester tester, Size size) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<AppController> _open(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  _screen(tester, size);
  final app = AppController(storage: _MemoryStorage());
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: SettingsScreen(app: app),
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

void main() {
  testWidgets('home: account, quick switches, sections with their values', (
    tester,
  ) async {
    final app = await _open(tester);
    expect(find.text('This phone only'), findsOneWidget);
    expect(find.text('Not synced yet'), findsOneWidget);
    expect(find.text('Quick settings'), findsOneWidget);
    expect(
      find.text('Cameras 500, 300, 200, 100 m · over limit +5 km/h'),
      findsOneWidget,
    );

    // Quick switches change the setting at once.
    expect(app.settings.keepScreenOn, isTrue);
    await tester.tap(find.text('Keep screen on'));
    await tester.pump();
    expect(app.settings.keepScreenOn, isFalse);
    await tester.tap(find.text('Voice warnings'));
    await tester.pump();
    expect(app.settings.muted, isTrue);
    await tester.scrollUntilVisible(find.text('Voice warnings are off'), 200);
    expect(find.text('Voice warnings are off'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Find police radar')),
      matchesSemantics(
        label: 'Find police radar',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ),
    );
  });

  testWidgets('a section opens on its own page and changes apply', (
    tester,
  ) async {
    final app = await _open(tester);
    await tester.tap(find.text('Warnings'));
    await tester.pumpAndSettle();
    expect(find.text('Warn me before'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Speed limit'), 200);
    expect(find.text('Speed limit'), findsOneWidget);

    // Bumps: add a warning at 500 m.
    await tester.scrollUntilVisible(find.text('500 m').at(1), -200);
    final bumpChip = find.text('500 m').at(1);
    await tester.ensureVisible(bumpChip);
    await tester.tap(bumpChip);
    await tester.pumpAndSettle();
    expect(app.settings.bumpDistances, contains(500));

    // Back home: the page is gone.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Warn me before'), findsNothing);

    await tester.scrollUntilVisible(find.text('Map & screen'), 200);
    await tester.tap(find.text('Map & screen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(app.settings.mapLook, MapLook.dark);
  });

  testWidgets('small phone, big text, dark: nothing is cut off', (
    tester,
  ) async {
    await _open(
      tester,
      size: const Size(320, 568),
      textScale: 1.3,
      brightness: Brightness.dark,
    );
    expect(tester.takeException(), isNull);
    for (final section in SettingsSection.values) {
      await tester.scrollUntilVisible(find.text(section.title), 200);
      await tester.tap(find.text(section.title));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: section.title);
      // Scroll the whole page.
      await tester.fling(
        find.byType(CustomScrollView).last,
        const Offset(0, -3000),
        3000,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: section.title);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('tablet: sections on the left, the open one on the right', (
    tester,
  ) async {
    final app = await _open(tester, size: const Size(1180, 820));
    expect(tester.takeException(), isNull);
    // Warnings is open next to the list, no page pushed.
    expect(find.text('Warn me before'), findsOneWidget);
    expect(find.text('Quick settings'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);

    await tester.ensureVisible(find.text('Map & screen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Map & screen'));
    await tester.pumpAndSettle();
    expect(find.text('Map style'), findsOneWidget);
    expect(find.text('Warn me before'), findsNothing);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(app.settings.mapLook, MapLook.light);
    expect(tester.takeException(), isNull);
  });
}
