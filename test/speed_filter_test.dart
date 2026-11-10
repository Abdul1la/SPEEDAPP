import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/models/app_settings.dart';
import 'package:new_project/services/alert_engine.dart';
import 'package:new_project/services/speed_filter.dart';
import 'package:new_project/utils/geo.dart';

/// [seconds] fixes, one a second, moving [metersPerSecond] north with the
/// phone reporting [reported] m/s.
List<DriveSample> run(
  SpeedFilter f, {
  required int seconds,
  required double metersPerSecond,
  required double reported,
  double wobble = 0,
  double accuracy = 5,
  double speedAccuracy = 0,
  int startSecond = 0,
  double startMeters = 0,
}) {
  final out = <DriveSample>[];
  var t = DateTime(2026, 1, 1).add(Duration(seconds: startSecond));
  for (var i = 0; i < seconds; i++) {
    // Parked phones wobble back and forth around one spot.
    final offset =
        startMeters + metersPerSecond * i + (i.isEven ? wobble : -wobble);
    final (lat, lng) = destinationPoint(36.8669, 42.9885, 0, offset);
    out.add(
      f.add(
        DriveSample(
          lat: lat,
          lng: lng,
          speedMps: reported,
          heading: 0,
          time: t,
        ),
        accuracyM: accuracy,
        speedAccuracyMps: speedAccuracy,
      ),
    );
    t = t.add(const Duration(seconds: 1));
  }
  return out;
}

void main() {
  test('standing still with a made-up 23 km/h shows 0', () {
    final out = run(
      SpeedFilter(),
      seconds: 10,
      metersPerSecond: 0,
      reported: 23 / 3.6,
      wobble: 3,
    );
    // The first seconds can't be judged yet; after that it's 0.
    expect(out.skip(4).every((s) => s.speedKmh == 0), isTrue);
    expect(out.last.stationary, isTrue);
    expect(out.last.heading, isNull);
  });

  test('poor GPS indoors (30 m accuracy) wobbling 12 m is still standing', () {
    final out = run(
      SpeedFilter(),
      seconds: 10,
      metersPerSecond: 0,
      reported: 4,
      wobble: 6,
      accuracy: 30,
    );
    expect(out.last.speedKmh, 0);
  });

  test('the phone says its speed is noise: 0', () {
    final out = run(
      SpeedFilter(),
      seconds: 2,
      metersPerSecond: 0,
      reported: 3,
      speedAccuracy: 2,
    );
    expect(out.last.speedKmh, 0);
  });

  test('real driving keeps the real speed', () {
    final out = run(
      SpeedFilter(),
      seconds: 10,
      metersPerSecond: 50 / 3.6,
      reported: 50 / 3.6,
    );
    expect(out.last.speedKmh, closeTo(50, 0.01));
    expect(out.last.stationary, isFalse);
    expect(out.last.heading, 0);
  });

  test('slow traffic at 10 km/h is not cut to 0', () {
    final out = run(
      SpeedFilter(),
      seconds: 10,
      metersPerSecond: 10 / 3.6,
      reported: 10 / 3.6,
    );
    expect(out.last.speedKmh, closeTo(10, 0.01));
  });

  test('a phone that reports no speed gets it from the movement', () {
    final out = run(
      SpeedFilter(),
      seconds: 10,
      metersPerSecond: 15,
      reported: -1,
    );
    expect(out.last.speedKmh, closeTo(54, 2));
  });

  test('highway speed is shown exactly as the GPS measures it', () {
    final out = run(
      SpeedFilter(),
      seconds: 10,
      metersPerSecond: 120 / 3.6,
      reported: 120 / 3.6,
      speedAccuracy: 0.5,
    );
    expect(out.last.speedKmh, closeTo(120, 0.01));
  });

  test('weak signal while driving slowly: the movement is the speed', () {
    // Between tall buildings the phone says its 25 km/h reading may be off
    // by 14 km/h, but the car clearly moved 40+ m in a few seconds.
    final out = run(
      SpeedFilter(),
      seconds: 10,
      metersPerSecond: 25 / 3.6,
      reported: 25 / 3.6,
      speedAccuracy: 4,
      accuracy: 10,
    );
    expect(out.last.speedKmh, closeTo(25, 1));
    expect(out.last.stationary, isFalse);
  });

  test('weak signal while parked stays 0', () {
    final out = run(
      SpeedFilter(),
      seconds: 10,
      metersPerSecond: 0,
      reported: 3,
      speedAccuracy: 4,
      accuracy: 10,
      wobble: 4,
    );
    expect(out.last.speedKmh, 0);
  });

  test('stopping at a light goes to 0 within a few seconds', () {
    final f = SpeedFilter();
    run(f, seconds: 10, metersPerSecond: 12, reported: 12);
    final stopped = run(
      f,
      seconds: 8,
      metersPerSecond: 0,
      reported: 5,
      wobble: 2,
      startSecond: 10,
      startMeters: 120,
    );
    expect(stopped.last.speedKmh, 0);
  });

  test('the engine keeps its direction while standing still', () {
    final engine = AlertEngine();
    var t = DateTime(2026, 1, 1);
    for (var m = 0.0; m < 300; m += 15) {
      final (lat, lng) = destinationPoint(36.8, 42.9, 90, m);
      engine.update(
        DriveSample(lat: lat, lng: lng, speedMps: 15, heading: 90, time: t),
        const [],
        const AppSettings(),
      );
      t = t.add(const Duration(seconds: 1));
    }
    expect(engine.course, 90);
    // Parked: the GPS wobbles 20 m to the north, but we're not driving north.
    final (lat, lng) = destinationPoint(36.8, 42.9, 0, 20);
    engine.update(
      DriveSample(lat: lat, lng: lng, speedMps: 0, time: t, stationary: true),
      const [],
      const AppSettings(),
    );
    expect(engine.course, 90);
  });
}
