import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/models/app_settings.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/services/alert_engine.dart';
import 'package:new_project/utils/geo.dart';

const settings = AppSettings(
  cameraDistances: [500, 300, 200, 100],
  bumpDistances: [300, 100],
  overSpeedTolerance: 5,
);

const camera = SpeedPoint(
  id: 'cam',
  type: PointType.camera,
  lat: 33.3,
  lng: 44.4,
  speedLimit: 80,
);

/// Drives in a straight line along [bearing], starting [startBefore] meters
/// before [target] and ending [endAfter] meters past it, one sample per
/// second. Returns every event, in order.
List<AlertEvent> drive(
  AlertEngine engine,
  List<SpeedPoint> points, {
  SpeedPoint target = camera,
  double bearing = 0,
  double kmh = 60,
  double startBefore = 800,
  double endAfter = 300,
  DateTime? start,
}) {
  final (sLat, sLng) = destinationPoint(
    target.lat,
    target.lng,
    bearing + 180,
    startBefore,
  );
  final step = kmh / 3.6;
  var t = start ?? DateTime(2026, 1, 1);
  final events = <AlertEvent>[];
  for (double m = 0; m <= startBefore + endAfter; m += step) {
    final (lat, lng) = destinationPoint(sLat, sLng, bearing, m);
    final r = engine.update(
      DriveSample(
        lat: lat,
        lng: lng,
        speedMps: step,
        heading: bearing,
        time: t,
      ),
      points,
      settings,
    );
    events.addAll(r.events);
    t = t.add(const Duration(seconds: 1));
  }
  return events;
}

List<int> approachDistances(List<AlertEvent> events) => events
    .where((e) => e.kind == AlertEventKind.approach)
    .map((e) => e.distance)
    .toList();

void main() {
  test('announces every warning distance once, far to near', () {
    final events = drive(AlertEngine(), [camera]);
    expect(approachDistances(events), [500, 300, 200, 100]);
    expect(events.where((e) => e.kind == AlertEventKind.overSpeed), isEmpty);
  });

  test('bump uses its own distances', () {
    const bump = SpeedPoint(
      id: 'b',
      type: PointType.bump,
      lat: 33.3,
      lng: 44.4,
    );
    final events = drive(AlertEngine(), [bump], target: bump);
    expect(approachDistances(events), [300, 100]);
  });

  test('no warning for a camera behind us', () {
    // Start right at the camera and drive away from it.
    final events = drive(
      AlertEngine(),
      [camera],
      startBefore: 0,
      endAfter: 700,
    );
    // Only the very first sample (on top of it) may count; nothing after.
    expect(approachDistances(events).length, lessThanOrEqualTo(1));
  });

  test('no warning when the camera is for the other direction', () {
    final southbound = camera.copyWith(direction: () => 180);
    final events = drive(AlertEngine(), [southbound], target: southbound);
    expect(events, isEmpty);
  });

  test('warns when the camera direction matches ours', () {
    final northbound = camera.copyWith(direction: () => 5);
    final events = drive(AlertEngine(), [northbound], target: northbound);
    expect(approachDistances(events), [500, 300, 200, 100]);
  });

  test('starting inside the zone announces only the nearest distance', () {
    final events = drive(AlertEngine(), [camera], startBefore: 250);
    expect(approachDistances(events), [300, 200, 100]);
  });

  test('over speed warning repeats at most every 10 seconds', () {
    final events = drive(AlertEngine(), [camera], kmh: 100);
    final over = events.where((e) => e.kind == AlertEventKind.overSpeed);
    // ~500 m at 27.8 m/s = 18 s in the zone -> 2 warnings.
    expect(over.length, inInclusiveRange(1, 2));
  });

  test('warns again on the next approach after leaving', () {
    final engine = AlertEngine();
    final first = drive(engine, [camera], endAfter: 900);
    final second = drive(engine, [camera], start: DateTime(2026, 1, 2));
    expect(approachDistances(first), [500, 300, 200, 100]);
    expect(approachDistances(second), [500, 300, 200, 100]);
  });

  test('GPS jitter around a distance does not repeat the warning', () {
    final engine = AlertEngine();
    var t = DateTime(2026, 1, 1);
    final events = <AlertEvent>[];
    // Hover around 300 m south of the camera, heading north.
    for (final m in <double>[310, 298, 305, 296, 303, 299, 301, 295]) {
      final (lat, lng) = destinationPoint(camera.lat, camera.lng, 180, m);
      events.addAll(
        engine.update(
          DriveSample(lat: lat, lng: lng, speedMps: 5, heading: 0, time: t),
          [camera],
          settings,
        ).events,
      );
      t = t.add(const Duration(seconds: 1));
    }
    // 310 m is inside the 500 m zone, then 300 m is crossed once only.
    expect(approachDistances(events), [500, 300]);
  });

  test('works without GPS heading (course from movement)', () {
    final engine = AlertEngine();
    final (sLat, sLng) = destinationPoint(camera.lat, camera.lng, 180, 800);
    var t = DateTime(2026, 1, 1);
    final events = <AlertEvent>[];
    for (double m = 0; m <= 1100; m += 16) {
      final (lat, lng) = destinationPoint(sLat, sLng, 0, m);
      events.addAll(
        engine.update(DriveSample(lat: lat, lng: lng, speedMps: 0, time: t), [
          camera,
        ], settings).events,
      );
      t = t.add(const Duration(seconds: 1));
    }
    expect(approachDistances(events), [500, 300, 200, 100]);
  });

  test('banner shows the nearest point ahead', () {
    const far = SpeedPoint(id: 'far', type: PointType.camera, lat: 0, lng: 0);
    final (nLat, nLng) = destinationPoint(0, 0, 180, 200);
    final near = SpeedPoint(
      id: 'near',
      type: PointType.bump,
      lat: nLat,
      lng: nLng,
    );
    final (lat, lng) = destinationPoint(0, 0, 180, 450);
    final r = AlertEngine().update(
      DriveSample(
        lat: lat,
        lng: lng,
        speedMps: 10,
        heading: 0,
        time: DateTime(2026),
      ),
      [far, near],
      settings,
    );
    expect(r.active?.point.id, 'near');
    expect(r.active!.distance, closeTo(250, 2));
  });

  test('next ahead finds the point up the road, not behind', () {
    final engine = AlertEngine();
    final (aLat, aLng) = destinationPoint(0, 0, 0, 2000); // 2 km north
    final (bLat, bLng) = destinationPoint(0, 0, 180, 1000); // 1 km south
    final ahead = SpeedPoint(
      id: 'ahead',
      type: PointType.camera,
      lat: aLat,
      lng: aLng,
    );
    final behind = SpeedPoint(
      id: 'behind',
      type: PointType.camera,
      lat: bLat,
      lng: bLng,
    );
    final s = DriveSample(
      lat: 0,
      lng: 0,
      speedMps: 15,
      heading: 0,
      time: DateTime(2026),
    );
    engine.update(s, [ahead, behind], settings);
    final next = engine.nextAhead(s, [ahead, behind]);
    expect(next?.point.id, 'ahead');
    expect(next!.distance, closeTo(2000, 5));
  });

  group('geo', () {
    test('distance is about right', () {
      // 1 degree of latitude ~ 111.2 km
      expect(distanceMeters(0, 0, 1, 0), closeTo(111195, 50));
    });
    test('bearing east', () {
      expect(bearingDegrees(0, 0, 0, 1), closeTo(90, 0.01));
    });
    test('angle difference wraps around north', () {
      expect(angleDifference(350, 10), 20);
    });
    test('destinationPoint round trip', () {
      final (lat, lng) = destinationPoint(33.3, 44.4, 45, 1000);
      expect(distanceMeters(33.3, 44.4, lat, lng), closeTo(1000, 0.5));
      expect(bearingDegrees(33.3, 44.4, lat, lng), closeTo(45, 0.1));
    });
  });

  test('a U-turn back to a two-way point warns again', () {
    const bump = SpeedPoint(
      id: 'b',
      type: PointType.bump,
      lat: 33.3,
      lng: 44.4,
    );
    final engine = AlertEngine();
    final there = drive(
      engine,
      [bump],
      target: bump,
      startBefore: 400,
      endAfter: 250,
    );
    expect(approachDistances(there), [300, 100]);
    final back = drive(
      engine,
      [bump],
      target: bump,
      bearing: 180,
      startBefore: 250,
      endAfter: 100,
      start: DateTime(2026, 1, 1, 0, 5),
    );
    // Back inside the 300 m zone: warned again, then at 100 m.
    expect(approachDistances(back), [300, 100]);
  });

  test('a U-turn back to a one-way point stays quiet (wrong direction)', () {
    const camNorth = SpeedPoint(
      id: 'n',
      type: PointType.camera,
      lat: 33.3,
      lng: 44.4,
      direction: 0,
    );
    final engine = AlertEngine();
    drive(
      engine,
      [camNorth],
      target: camNorth,
      startBefore: 600,
      endAfter: 300,
    );
    final back = drive(
      engine,
      [camNorth],
      target: camNorth,
      bearing: 180,
      startBefore: 300,
      endAfter: 100,
      start: DateTime(2026, 1, 1, 0, 5),
    );
    expect(approachDistances(back), isEmpty);
  });
}
