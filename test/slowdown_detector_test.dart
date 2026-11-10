import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/services/alert_engine.dart';
import 'package:new_project/services/slowdown_detector.dart';

/// A drive: one reading per second at these speeds (km/h), going north
/// (or turning, with [headings]).
List<Slowdown> drive(List<double> speeds, {List<double>? headings}) {
  final d = SlowdownDetector();
  final start = DateTime(2026, 11, 10, 12);
  final found = <Slowdown>[];
  var lat = 36.8;
  for (var i = 0; i < speeds.length; i++) {
    lat += speeds[i] / 3.6 / 111320;
    final s = d.add(
      DriveSample(
        lat: lat,
        lng: 43,
        speedMps: speeds[i] / 3.6,
        time: start.add(Duration(seconds: i)),
        heading: headings?[i] ?? 0,
      ),
    );
    if (s != null) found.add(s);
  }
  return found;
}

List<double> repeat(double kmh, int seconds) => List.filled(seconds, kmh);

void main() {
  test('brake for a radar, pass it, speed up again: found', () {
    final found = drive([
      ...repeat(100, 15),
      90, 80, 70, 65, // brake
      ...repeat(65, 4), // pass the radar
      70, 78, 85, 92, ...repeat(95, 5), // speed up
    ]);
    expect(found, hasLength(1));
    final s = found.single;
    expect(s.speedBefore, 100);
    expect(s.speedMin, 65);
    expect(s.toJson()['heading'], 0);
  });

  test('stopping (a light, a jam, a checkpoint) is not counted', () {
    final found = drive([
      ...repeat(100, 15),
      80, 60, 40, 20, 10, 0, 0, 0, // stop
      20, 40, 60, 80, ...repeat(100, 5),
    ]);
    expect(found, isEmpty);
  });

  test('slowing gently (traffic getting heavier) is not counted', () {
    final found = drive([
      ...repeat(100, 10),
      for (var v = 100.0; v >= 70; v -= 1.5) v, // 20 s to lose 30 km/h
      ...repeat(70, 5),
      ...repeat(95, 10),
    ]);
    expect(found, isEmpty);
  });

  test('entering a town (stays slow) is not counted', () {
    final found = drive([...repeat(100, 15), 85, 70, 60, ...repeat(60, 40)]);
    expect(found, isEmpty);
  });

  test('braking for a curve or a turn is not counted', () {
    final speeds = <double>[
      ...repeat(90, 15),
      75,
      60,
      55,
      55,
      60,
      70,
      80,
      ...repeat(90, 5),
    ];
    final headings = [
      for (var i = 0; i < speeds.length; i++) i < 17 ? 0.0 : 90.0,
    ];
    expect(drive(speeds, headings: headings), isEmpty);
  });

  test('slow roads are not counted', () {
    expect(
      drive(<double>[...repeat(50, 15), 30, 25, 25, 40, ...repeat(50, 5)]),
      isEmpty,
    );
  });

  test('two brakes close together count once', () {
    final brake = <double>[90, 75, 65, 65, 75, 88, ...repeat(100, 10)];
    expect(drive([...repeat(100, 15), ...brake, ...brake]), hasLength(1));
  });

  test('a GPS gap starts over', () {
    final d = SlowdownDetector();
    final t = DateTime(2026, 11, 10, 12);
    DriveSample at(int s, double kmh) => DriveSample(
      lat: 36.8,
      lng: 43,
      speedMps: kmh / 3.6,
      time: t.add(Duration(seconds: s)),
    );
    for (var i = 0; i < 15; i++) {
      d.add(at(i, 100));
    }
    d.add(at(16, 70)); // braking
    // 20 s without GPS (a tunnel), then faster: not a slowdown.
    expect(d.add(at(36, 90)), isNull);
  });
}
