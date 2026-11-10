import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/app_controller.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/services/storage.dart';
import 'package:new_project/theme/app_theme.dart';
import 'package:new_project/widgets/point_editor.dart';

/// Keeps points in memory instead of on the phone.
class _MemoryStorage extends Storage {
  List<SpeedPoint> saved = [];
  @override
  Future<void> savePoints(List<SpeedPoint> points) async => saved = points;
}

Future<void> _open(
  WidgetTester tester,
  AppController app, {
  SpeedPoint? existing,
  Size size = const Size(360, 740),
  LatLngPair? myLocation,
  PointPlace place = PointPlace.mapSpot,
  bool fromLongPress = true,
  bool presetDirection = false,
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showPointEditor(
              context,
              app,
              existing: existing,
              lat: 33.3,
              lng: 44.4,
              myLocation: myLocation,
              place: place,
              fromLongPress: fromLongPress,
              myCourse: 37,
              presetDirection: presetDirection,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('new point: pick bump, limit, direction, save', (tester) async {
    final storage = _MemoryStorage();
    final app = AppController(storage: storage);
    await _open(tester, app);
    expect(tester.takeException(), isNull);
    expect(find.text('New warning point'), findsOneWidget);

    await tester.tap(find.text('Speed bump'));
    await tester.pump();
    await tester.tap(find.text('30'));
    await tester.pump();
    await tester.ensureVisible(find.text('One way'));
    await tester.tap(find.text('One way'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('E'));
    await tester.tap(find.text('E'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(storage.saved, hasLength(1));
    final p = storage.saved.single;
    expect(p.type, PointType.bump);
    expect(p.speedLimit, 30);
    expect(p.direction, 90);
  });

  testWidgets('new points start as "both ways" (parked or on the map)', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final app = AppController(storage: storage);
    await _open(tester, app);
    expect(find.text('NE 37°'), findsNothing); // no compass
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(storage.saved.single.direction, isNull);
  });

  testWidgets('"my direction" is preselected while driving', (tester) async {
    final app = AppController(storage: _MemoryStorage());
    await _open(tester, app, presetDirection: true);
    expect(find.text('NE 37°'), findsOneWidget); // compass center
    expect(find.text('My direction · NE'), findsOneWidget);
  });

  testWidgets('"Both ways" hides the compass and saves no direction', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final app = AppController(storage: storage);
    await _open(tester, app, presetDirection: true);
    expect(find.text('NE 37°'), findsOneWidget);

    await tester.tap(find.text('Both ways'));
    await tester.pumpAndSettle();
    expect(find.text('NE 37°'), findsNothing); // compass hidden

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(storage.saved.single.direction, isNull);
  });

  testWidgets('edit point shows delete and fits a small phone', (tester) async {
    final storage = _MemoryStorage();
    final app = AppController(storage: storage);
    const p = SpeedPoint(
      id: 'x',
      type: PointType.camera,
      lat: 1,
      lng: 2,
      speedLimit: 80,
      direction: 200, // not one of the 8 compass points
    );
    await app.addPoint(p);
    await _open(tester, app, existing: p, size: const Size(320, 568));
    expect(tester.takeException(), isNull);
    expect(find.text('Edit point'), findsOneWidget);
    expect(find.text('S 200°'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('Delete'));
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(storage.saved, isEmpty);
  });

  testWidgets('Add button: the new point starts at my GPS location', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final app = AppController(storage: storage);
    await _open(
      tester,
      app,
      myLocation: (lat: 33.31, lng: 44.36),
      place: PointPlace.myLocation,
      fromLongPress: false,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('My location'), findsOneWidget);
    expect(find.text('Map center'), findsOneWidget);
    expect(find.text('Your GPS position.'), findsOneWidget);
    expect(find.textContaining('33.31000, 44.36000'), findsOneWidget);

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final p = storage.saved.single;
    expect((p.lat, p.lng), (33.31, 44.36));
  });

  testWidgets('switching to the map spot saves it there instead', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final app = AppController(storage: storage);
    await _open(
      tester,
      app,
      myLocation: (lat: 33.31, lng: 44.36),
      place: PointPlace.myLocation,
    );
    await tester.tap(find.text('Pressed spot'));
    await tester.pumpAndSettle();
    expect(find.textContaining('33.30000, 44.40000'), findsOneWidget);

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final p = storage.saved.single;
    expect((p.lat, p.lng), (33.3, 44.4));
  });

  testWidgets('without GPS the map spot is used and "My location" waits', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final app = AppController(storage: storage);
    await _open(
      tester,
      app,
      place: PointPlace.myLocation,
      fromLongPress: false,
    );
    expect(find.textContaining('waiting for GPS'), findsOneWidget);
    await tester.tap(find.text('My location')); // not available: stays
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final p = storage.saved.single;
    expect((p.lat, p.lng), (33.3, 44.4));
  });

  testWidgets('editing an existing point has no location choice', (
    tester,
  ) async {
    final app = AppController(storage: _MemoryStorage());
    const p = SpeedPoint(id: 'e', type: PointType.bump, lat: 1, lng: 2);
    await app.addPoint(p);
    await _open(tester, app, existing: p, myLocation: (lat: 5, lng: 6));
    expect(find.text('My location'), findsNothing);
    expect(find.textContaining('1.00000, 2.00000'), findsOneWidget);
  });
}
