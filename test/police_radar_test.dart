// Police radar in the app: saved fields, expiry, the trust line, and the
// "still there?" question after driving past one.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/app_controller.dart';
import 'package:new_project/models/app_settings.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/models/warning_tone.dart';
import 'package:new_project/services/alert_engine.dart';
import 'package:new_project/services/location_service.dart';
import 'package:new_project/services/storage.dart';
import 'package:new_project/services/voice_player.dart';
import 'package:new_project/widgets/hud.dart';

class _MemoryStorage extends Storage {
  @override
  Future<void> savePoints(List<SpeedPoint> points) async {}
  @override
  Future<void> saveSettings(AppSettings s) async {}
  @override
  Future<void> saveCommunity(List<SpeedPoint> points) async {}
}

/// Writes down the warnings instead of playing them.
class _SilentVoice extends VoicePlayer {
  final said = <AlertEvent>[];
  @override
  void announce(AlertEvent e) => said.add(e);
  @override
  Future<void> dispose() async {}
}

/// GPS readings the test sends.
class _FakeGps extends LocationService {
  final controller = StreamController<DriveSample>.broadcast();
  @override
  Future<LocationStatus> ensurePermission({bool ask = true}) async =>
      LocationStatus.ok;
  @override
  Stream<DriveSample> gps() => controller.stream;
}

final now = DateTime.now();

SpeedPoint radar({
  String id = 'r1',
  double lat = 36.8,
  Duration expiresIn = const Duration(hours: 1),
  int confirms = 0,
  bool auto = false,
  int slowdowns = 0,
}) => SpeedPoint(
  id: id,
  type: PointType.mobile,
  lat: lat,
  lng: 43,
  remoteId: id,
  community: true,
  expiresAt: now.add(expiresIn),
  confirms: confirms,
  auto: auto,
  slowdowns: slowdowns,
  createdAt: now.subtract(const Duration(minutes: 12)),
);

void main() {
  test('police radar is temporary, warns at 500 m and 200 m, with "Alert"', () {
    expect(PointType.mobile.temporary, isTrue);
    expect(PointType.camera.temporary, isFalse);
    const s = AppSettings();
    expect(s.distancesFor(PointType.mobile), [500, 200]);
    expect(s.toneFor(PointType.mobile), WarningTone.alert);
  });

  test('its fields survive saving, and it knows when it expired', () {
    final p = radar(auto: true, slowdowns: 4, confirms: 2);
    final back = SpeedPoint.fromJson(
      jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
    );
    expect(back.type, PointType.mobile);
    expect(back.auto, isTrue);
    expect(back.slowdowns, 4);
    expect(back.confirms, 2);
    expect(back.expiresAt!.difference(p.expiresAt!).inSeconds, 0);
    expect(back.isExpired(), isFalse);
    expect(back.isExpired(now.add(const Duration(hours: 2))), isTrue);
  });

  test('read from the server', () {
    final p = SpeedPoint.fromServer({
      'id': '7',
      'type': 'mobile',
      'lat': 36.8,
      'lng': 43.0,
      'visibility': 'public',
      'mine': false,
      'confirmCount': 0,
      'goneCount': 0,
      'expiresAt': '2026-11-10T18:00:00.000Z',
      'auto': true,
      'slowdownCount': 3,
      'createdAt': '2026-11-10T16:00:00.000Z',
    });
    expect(p.type, PointType.mobile);
    expect(p.auto, isTrue);
    expect(p.slowdowns, 3);
    expect(p.expiresAt, DateTime.utc(2026, 11, 10, 18));
  });

  test('the trust line says how sure the app is', () {
    expect(
      radarTrust(radar(auto: true, slowdowns: 4), now),
      '4 drivers braked here · 12 min ago',
    );
    expect(
      radarTrust(radar(confirms: 3), now),
      'Confirmed by 3 drivers · 12 min ago',
    );
    expect(radarTrust(radar(), now), 'Reported 12 min ago · not confirmed yet');
  });

  test('an expired police radar is not on the map', () async {
    final app = AppController(storage: _MemoryStorage());
    await app.setCommunity([
      radar(id: 'old', expiresIn: const Duration(minutes: -1)),
      radar(id: 'new', lat: 36.9),
    ]);
    expect(app.mapPoints.map((p) => p.id), ['new']);
  });

  test('driving past a police radar asks "still there?"', () async {
    final gps = _FakeGps();
    final voice = _SilentVoice();
    final app = AppController(
      storage: _MemoryStorage(),
      location: gps,
      voice: voice,
    );
    await app.setCommunity([radar()]);
    await app.startGps(ask: false);

    // North at 72 km/h (20 m/s), one reading a second, past the radar at
    // 36.8.
    var t = now;
    for (var m = -600.0; m <= 300; m += 20) {
      t = t.add(const Duration(seconds: 1));
      gps.controller.add(
        DriveSample(
          lat: 36.8 + m / 111320,
          lng: 43,
          speedMps: 20,
          heading: 0,
          time: t,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      if (m < 150) expect(app.askStillThere, isNull, reason: 'at $m m');
    }
    expect(app.askStillThere?.id, 'r1');
    // It warned before, at 500 m and 200 m.
    expect(
      [
        for (final e in voice.said)
          if (e.kind == AlertEventKind.approach) e.distance,
      ],
      [500, 200],
    );

    app.dismissStillThere();
    expect(app.askStillThere, isNull);
    await gps.controller.close();
    app.dispose();
  });
}
