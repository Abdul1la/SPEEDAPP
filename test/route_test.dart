import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:new_project/app_controller.dart';
import 'package:new_project/models/app_settings.dart';
import 'package:new_project/models/route_plan.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/screens/search_screen.dart';
import 'package:new_project/services/alert_engine.dart';
import 'package:new_project/services/api_client.dart';
import 'package:new_project/services/storage.dart';
import 'package:new_project/theme/app_theme.dart';
import 'package:new_project/utils/geo.dart';
import 'package:new_project/utils/polyline.dart';
import 'package:new_project/widgets/route_sheet.dart';
import 'package:new_project/widgets/ui.dart';

/// Google polyline encoder (precision 6), the inverse of decodePolyline.
String encode(List<(double, double)> path) {
  final out = StringBuffer();
  var pLat = 0;
  var pLng = 0;
  void put(int v) {
    var n = v < 0 ? ~(v << 1) : v << 1;
    while (n >= 0x20) {
      out.writeCharCode((0x20 | (n & 0x1f)) + 63);
      n >>= 5;
    }
    out.writeCharCode(n + 63);
  }

  for (final (lat, lng) in path) {
    final la = (lat * 1e6).round();
    final ln = (lng * 1e6).round();
    put(la - pLat);
    put(ln - pLng);
    pLat = la;
    pLng = ln;
  }
  return out.toString();
}

class _MemoryStorage extends Storage {
  List<Place> recent = [];
  @override
  Future<void> savePoints(List<SpeedPoint> points) async {}
  @override
  Future<void> saveSettings(AppSettings s) async {}
  @override
  Future<void> saveCommunity(List<SpeedPoint> points) async {}
  @override
  Future<List<Place>> loadRecentPlaces() async => recent;
  @override
  Future<void> saveRecentPlaces(List<Place> places) async => recent = places;
}

const duhok = (lat: 36.8669, lng: 42.9885);
final north2km = destinationPoint(duhok.lat, duhok.lng, 0, 2000);
final erbil = Place(
  id: 'R1',
  name: 'Erbil',
  address: 'Iraq',
  lat: north2km.$1,
  lng: north2km.$2,
  kind: 'city',
);

/// Place lookups the fake backend got (`GET /v1/places/:id`).
final lookups = <Uri>[];

/// A fake backend: two routes north (straight, and with a bend), one camera.
http.Client fakeBackend({int routesStatus = 200}) =>
    MockClient((request) async {
      final path = request.url.path;
      if (path == '/v1/places' &&
          request.url.queryParameters['q']!.contains('lelav')) {
        // Google results: no spot until picked.
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'g:LELAV_123',
                'name': 'Lelav City',
                'address': 'Nzarke, Duhok, Iraq',
                'lat': null,
                'lng': null,
                'kind': 'neighbourhood',
                'distanceM': 4200,
              },
            ],
            'source': 'google',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.url.pathSegments.length == 3 &&
          request.url.pathSegments[1] == 'places') {
        lookups.add(request.url);
        if (request.url.pathSegments.last != 'g:LELAV_123') {
          return http.Response(
            jsonEncode({
              'error': {'code': 'place_not_found', 'message': 'Not found.'},
            }),
            404,
          );
        }
        return http.Response(
          jsonEncode({
            'place': {
              'id': 'g:LELAV_123',
              'name': '',
              'address': 'Nzarke, Duhok',
              'lat': 36.84,
              'lng': 43.01,
              'kind': 'neighbourhood',
            },
          }),
          200,
        );
      }
      if (path == '/v1/places') {
        return http.Response(
          jsonEncode({
            'places': [
              {
                'id': 'R1',
                'name': 'Duhok',
                'address': 'Duhok, Iraq',
                'lat': 36.85,
                'lng': 42.99,
                'kind': 'city',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (path == '/v1/routes') {
        if (routesStatus != 200) {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'no_route',
                'message': 'No driving route was found.',
              },
            }),
            routesStatus,
          );
        }
        final straight = [(duhok.lat, duhok.lng), north2km];
        final east = destinationPoint(duhok.lat, duhok.lng, 90, 500);
        final bend = [
          (duhok.lat, duhok.lng),
          east,
          destinationPoint(east.$1, east.$2, 0, 2000),
          north2km,
        ];
        final cam = destinationPoint(duhok.lat, duhok.lng, 0, 1000);
        return http.Response(
          jsonEncode({
            'routes': [
              {
                'distanceM': 2000,
                'durationS': 180,
                'summary': 'Zakho Road',
                'polyline': encode(straight),
                'cameras': 1,
                'bumps': 0,
                'mobiles': 0,
                'pointIds': ['77'],
                'steps': [
                  {
                    'instruction': 'Head north on Zakho Road',
                    'type': 'depart',
                    'modifier': '',
                    'name': 'Zakho Road',
                    'distanceM': 2000,
                    'durationS': 180,
                    'lat': duhok.lat,
                    'lng': duhok.lng,
                  },
                  {
                    'instruction': 'Arrive at your destination',
                    'type': 'arrive',
                    'modifier': '',
                    'name': '',
                    'distanceM': 0,
                    'durationS': 0,
                    'lat': north2km.$1,
                    'lng': north2km.$2,
                  },
                ],
              },
              {
                'distanceM': 3000,
                'durationS': 300,
                'summary': 'Ring Road',
                'polyline': encode(bend),
                'cameras': 0,
                'bumps': 0,
                'pointIds': [],
              },
            ],
            'points': [
              {
                'id': '77',
                'type': 'camera',
                'lat': cam.$1,
                'lng': cam.$2,
                'speedLimit': 80,
                'direction': null,
                'note': null,
                'visibility': 'public',
                'status': 'active',
                'confirmCount': 2,
                'goneCount': 0,
                'lastConfirmedAt': null,
                'mine': false,
                'myVote': null,
                'createdAt': '2026-01-01T00:00:00Z',
                'updatedAt': '2026-01-01T00:00:00Z',
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });

AppController appWith(http.Client client, [Storage? storage]) => AppController(
  storage: storage ?? _MemoryStorage(),
  api: ApiClient(baseUrl: 'http://test', client: client),
);

DriveSample at((double, double) p, {double kmh = 50, DateTime? time}) =>
    DriveSample(
      lat: p.$1,
      lng: p.$2,
      speedMps: kmh / 3.6,
      heading: 0,
      time: time ?? DateTime.now(),
    );

void main() {
  test('decodes the route lines the server sends', () {
    final path = decodePolyline(
      encode([(36.8669, 42.9885), (37.1, 42.7), (36.19, 44.0092)]),
    );
    expect(path.map((p) => (p.lat, p.lng)), [
      (36.8669, 42.9885),
      (37.1, 42.7),
      (36.19, 44.0092),
    ]);
  });

  test('progress along a route: meters left and distance from it', () {
    final r = RouteOption(
      distanceM: 2000,
      durationS: 180,
      summary: '',
      path: decodePolyline(encode([(duhok.lat, duhok.lng), north2km])),
      cameras: 0,
      bumps: 0,
      pointIds: const [],
    );
    final half = destinationPoint(duhok.lat, duhok.lng, 0, 1000);
    expect(r.progress(half.$1, half.$2).remainingM, closeTo(1000, 5));
    final aside = destinationPoint(half.$1, half.$2, 90, 120);
    expect(r.progress(aside.$1, aside.$2).offRouteM, closeTo(120, 5));
  });

  test('plan, choose, drive and arrive', () async {
    final app = appWith(fakeBackend());
    final messages = <String>[];
    final sub = app.messages.listen(messages.add);
    var t = DateTime(2026, 1, 1);
    app.debugGpsFix(at((duhok.lat, duhok.lng), time: t));

    await app.planRoute(erbil);
    expect(app.routeOptions, hasLength(2));
    expect(app.routeOptions.first.summary, 'Zakho Road');
    // The camera on the route warns even if it wasn't downloaded before.
    expect(app.mapPoints.any((p) => p.remoteId == '77'), isTrue);

    app.selectRoute(1);
    expect(app.route!.summary, 'Ring Road');
    app.selectRoute(0);
    app.startRoute();
    expect(app.routeActive, isTrue);
    expect(app.remainingM, closeTo(2000, 10));

    final mid = destinationPoint(duhok.lat, duhok.lng, 0, 1500);
    t = t.add(const Duration(minutes: 2));
    app.debugGpsFix(at(mid, time: t));
    expect(app.remainingM, closeTo(500, 10));
    expect(app.remainingS, closeTo(45, 2));

    // Off the route for a while: "You left the route".
    final off = destinationPoint(mid.$1, mid.$2, 90, 300);
    for (var i = 0; i < 20; i++) {
      t = t.add(const Duration(seconds: 1));
      app.debugGpsFix(at(off, time: t));
    }
    expect(app.offRoute, isTrue);

    // Back on it and at the end: arrived, route gone.
    app.debugGpsFix(at(north2km, time: t.add(const Duration(seconds: 30))));
    await Future<void>.delayed(Duration.zero);
    expect(app.routeActive, isFalse);
    expect(app.destination, isNull);
    expect(messages, ['You have arrived at Erbil']);
    expect(app.mapPoints.any((p) => p.remoteId == '77'), isFalse);
    await sub.cancel();
  });

  test('no route, and no GPS yet: clear errors', () async {
    final app = appWith(fakeBackend(routesStatus: 404));
    await expectLater(
      app.planRoute(erbil),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'no_gps')),
    );
    app.debugGpsFix(at((duhok.lat, duhok.lng)));
    await expectLater(
      app.planRoute(erbil),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'no_route')),
    );
    expect(app.routeOptions, isEmpty);
  });

  testWidgets('search: type, see results, pick one (kept as recent)', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final app = appWith(fakeBackend(), storage);
    Place? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked = await Navigator.push<Place>(
                context,
                MaterialPageRoute(
                  builder: (_) => SearchScreen(app: app, storage: storage),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Type a city'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'duh');
    await tester.pump(const Duration(milliseconds: 400)); // debounce
    await tester.pumpAndSettle();
    expect(find.text('Duhok'), findsOneWidget);
    // What it is, then where: "City · Duhok, Iraq".
    expect(find.textContaining('Duhok, Iraq'), findsOneWidget);

    await tester.tap(find.text('Duhok'));
    await tester.pumpAndSettle();
    expect(picked?.name, 'Duhok');
    expect(storage.recent.single.name, 'Duhok');
  });

  testWidgets('search: a Google result is looked up when picked', (
    tester,
  ) async {
    lookups.clear();
    final storage = _MemoryStorage();
    final app = appWith(fakeBackend(), storage);
    Place? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked = await Navigator.push<Place>(
                context,
                MaterialPageRoute(
                  builder: (_) => SearchScreen(app: app, storage: storage),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'lelav city');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('Lelav City'), findsOneWidget);
    expect(find.textContaining('Nzarke, Duhok, Iraq'), findsOneWidget);
    expect(find.text('4.2 km'), findsOneWidget); // from the search service
    expect(find.text('Google Maps'), findsOneWidget); // its credit

    await tester.tap(find.text('Lelav City'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(lookups, hasLength(1));
    final session = lookups.single.queryParameters['session']!;
    expect(session, matches(RegExp(r'^[A-Za-z0-9_-]{32}$')));
    expect(picked?.name, 'Lelav City');
    expect(picked?.address, 'Nzarke, Duhok, Iraq');
    expect(picked?.located, isTrue);
    expect((picked!.lat, picked!.lng), (36.84, 43.01));
    // Google's coordinates are not kept: looked up again next time.
    final saved = storage.recent.single.toJson();
    expect(saved.containsKey('lat'), isFalse);
    expect(Place.fromJson(saved).located, isFalse);
  });

  test('places: Google ones keep no coordinates; spot merged in', () {
    final hit = Place.fromJson({
      'id': 'g:X1',
      'name': 'Mazi Mall',
      'address': 'Duhok, Iraq',
      'lat': null,
      'lng': null,
      'kind': 'mall',
      'distanceM': 900,
    });
    expect(hit.located, isFalse);
    expect(hit.distanceM, 900);
    final spot = hit.locatedAt(
      const Place(id: 'g:X1', name: '', address: 'Zakho Rd', lat: 1, lng: 2),
    );
    expect(spot.located, isTrue);
    expect(
      (spot.name, spot.address, spot.kind),
      ('Mazi Mall', 'Duhok, Iraq', 'mall'),
    );
    expect(spot.toJson().containsKey('lat'), isFalse);
    // OpenStreetMap places keep theirs.
    const osm = Place(id: 'N5', name: 'Duhok', address: '', lat: 36.8, lng: 43);
    expect(Place.fromJson(osm.toJson()).located, isTrue);
    expect(placeKindLabel('mall'), 'Mall');
    expect(placeIcon('mall'), Icons.local_mall_rounded);
  });

  testWidgets('route sheet: options with cameras, choose one, Start', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final app = appWith(fakeBackend());
    app.debugGpsFix(at((duhok.lat, duhok.lng)));
    await tester.runAsync(() => app.planRoute(erbil));
    bool? started;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  started = await showRouteOptions(context, app),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('To Erbil'), findsOneWidget);
    expect(find.text('Fastest'), findsOneWidget);
    expect(find.textContaining('3 min'), findsOneWidget);
    expect(find.text('1 camera'), findsOneWidget);
    await tester.ensureVisible(find.text('via Ring Road'));
    await tester.pumpAndSettle();
    expect(
      find.text('No speed cameras or bumps known on this way'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('via Ring Road'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('via Ring Road'));
    await tester.pump();
    expect(app.selectedRoute, 1);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(started, isTrue);
  });

  test('what is on the way, in order, with how far along', () async {
    final app = appWith(fakeBackend());
    app.debugGpsFix(at((duhok.lat, duhok.lng)));
    await app.planRoute(erbil);
    final straight = app.routeOptions[0];
    expect(straight.steps.map((s) => s.type), ['depart', 'arrive']);
    expect(straight.steps.first.instruction, 'Head north on Zakho Road');
    final stops = straight.stopsFrom(app.mapPoints);
    expect(stops, hasLength(1));
    expect(stops.single.point.remoteId, '77');
    expect(stops.single.atM, closeTo(1000, 10));
    // The other way has none, and no directions came for it.
    expect(app.routeOptions[1].stopsFrom(app.mapPoints), isEmpty);
    expect(app.routeOptions[1].steps, isEmpty);
  });

  testWidgets('route details: place, trip, cameras on the way, directions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final app = appWith(fakeBackend());
    app.debugGpsFix(at((duhok.lat, duhok.lng)));
    await tester.runAsync(() => app.planRoute(erbil));
    bool? started;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  started = await showRouteOptions(context, app),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The sheet says what the place is and how far.
    expect(find.text('City · Iraq · 2.0 km away · 2 ways'), findsOneWidget);

    // The Details button on the card of the way via [road].
    Future<void> openDetails(String road) async {
      await tester.ensureVisible(find.text(road, skipOffstage: false));
      await tester.pumpAndSettle();
      final card = find.ancestor(
        of: find.text(road),
        matching: find.byType(AppCard),
      );
      await tester.tap(
        find.descendant(of: card, matching: find.text('Details')),
      );
      await tester.pumpAndSettle();
    }

    // Details of the second way: selects it, nothing on it.
    await openDetails('via Ring Road');
    expect(tester.takeException(), isNull);
    expect(app.selectedRoute, 1);
    expect(
      find.textContaining('No speed cameras or bumps known'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    // Details of the fastest way.
    await openDetails('via Zakho Road');
    expect(app.selectedRoute, 0);
    expect(find.text('Erbil'), findsOneWidget);
    expect(find.text('City'), findsOneWidget);
    expect(find.textContaining('2.0 km from you'), findsOneWidget);
    expect(find.textContaining('Arrive at about'), findsOneWidget);
    expect(find.text('via Zakho Road'), findsOneWidget);
    expect(find.text('1 speed camera'), findsOneWidget);
    expect(find.text('On the way · 1'), findsOneWidget);
    expect(find.text('Speed camera'), findsOneWidget);
    expect(find.textContaining('at 1.0 km'), findsOneWidget);
    expect(find.text('80'), findsOneWidget); // its speed limit sign
    await tester.scrollUntilVisible(
      find.text('Arrive at your destination'),
      200,
    );
    expect(find.text('Head north on Zakho Road'), findsOneWidget);
    expect(find.text('then 2.0 km'), findsOneWidget);

    // Start from the details page: both pages close, route starts.
    await tester.tap(find.text('Start this route'));
    await tester.pumpAndSettle();
    expect(started, isTrue);
    expect(find.text('To Erbil'), findsNothing);
  });

  test('durations read naturally', () {
    expect(formatDuration(30), '1 min');
    expect(formatDuration(47 * 60), '47 min');
    expect(formatDuration(137 * 60), '2 h 17 min');
    expect(formatDuration(120 * 60), '2 h');
  });

  unawaited(Future<void>.value());
}
