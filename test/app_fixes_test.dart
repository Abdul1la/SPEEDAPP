import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/app_controller.dart';
import 'package:new_project/models/app_settings.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/services/storage.dart';
import 'package:new_project/services/voice_player.dart';
import 'package:new_project/utils/geo.dart';
import 'package:new_project/services/alert_engine.dart';

/// Keeps everything in memory instead of on the phone.
class _MemoryStorage extends Storage {
  List<SpeedPoint> saved = [];
  @override
  Future<void> savePoints(List<SpeedPoint> points) async => saved = points;
  @override
  Future<void> saveSettings(AppSettings s) async {}
  @override
  Future<void> saveCommunity(List<SpeedPoint> points) async {}
}

/// Plays nothing (unit tests have no audio).
class _SilentVoice extends VoicePlayer {
  @override
  void announce(AlertEvent e) {}
  @override
  Future<void> stopAll() async {}
}

const _point = SpeedPoint(
  id: 'p1',
  type: PointType.camera,
  lat: 33.3,
  lng: 44.4,
  speedLimit: 60,
);

void main() {
  test(
    'saving from an editor opened before the upload keeps the server id',
    () async {
      final app = AppController(storage: _MemoryStorage());
      await app.addPoint(_point);
      final openedEditorWith = app.points.single; // no server id yet
      // The upload finishes while the editor is open.
      await app.setMyPoints([
        app.points.single.copyWith(remoteId: () => '42', dirty: false),
      ]);
      await app.updatePoint(openedEditorWith.copyWith(speedLimit: () => 80));
      final p = app.points.single;
      expect(p.remoteId, '42');
      expect(p.speedLimit, 80);
      expect(p.dirty, isTrue);
    },
  );

  test(
    'a community point only takes the sound and repeat from the editor',
    () async {
      final app = AppController(storage: _MemoryStorage());
      const c = SpeedPoint(
        id: 'c9',
        type: PointType.bump,
        lat: 1,
        lng: 2,
        remoteId: '9',
        community: true,
        confirms: 3,
      );
      await app.setCommunity([c]);
      await app.updatePoint(
        c.copyWith(confirms: 0, repeat: () => 2, speedLimit: () => 30),
      );
      final p = app.community.single;
      expect(p.repeat, 2);
      expect(p.confirms, 3);
      expect(p.speedLimit, isNull);
    },
  );

  test('imported points are private when "Share new points" is off', () async {
    final app = AppController(storage: _MemoryStorage());
    await app.updateSettings(app.settings.copyWith(sharePoints: false));
    await app.importPoints('33.31, 44.36, camera, 80');
    expect(app.points.single.shared, isFalse);
    expect(app.points.single.dirty, isTrue);
  });

  test('undo of a delete puts the point back', () async {
    final app = AppController(storage: _MemoryStorage());
    await app.addPoint(_point);
    final p = app.points.single;
    await app.deletePoint(p.id);
    expect(app.points, isEmpty);
    await app.restorePoint(p);
    expect(app.points.single.id, 'p1');
  });

  group('imported lists are cleaned', () {
    test('bad limits, directions and long notes', () {
      final long = 'x' * 300;
      final p = parsePoints(
        '[{"lat":33.3,"lng":44.4,"limit":2,"dir":370,"note":"$long"},'
        '{"lat":95,"lng":44.4},{"lat":"a","lng":1}]',
      );
      expect(p, hasLength(1));
      expect(p.single.speedLimit, isNull);
      expect(p.single.direction, 10);
      expect(p.single.note, hasLength(maxNoteLength));
    });

    test('CSV keeps good values', () {
      final p = parsePoints('33.3, 44.4, bump, 30, 90').single;
      expect(p.type, PointType.bump);
      expect(p.speedLimit, 30);
      expect(p.direction, 90);
    });
  });

  test('what is sent to the server is always valid', () {
    final json = _point
        .copyWith(
          direction: () => 359.7,
          note: () => '  ${'n' * 250}  ',
          speedLimit: () => 900,
        )
        .toServerJson();
    expect(json['direction'], 0);
    expect((json['note'] as String).length, maxNoteLength);
    expect(json['speedLimit'], isNull);
  });

  test(
    'mute is not backed up, and a restore keeps this phone muted or not',
    () {
      final muted = const AppSettings().copyWith(muted: true);
      expect(muted.toBackupJson().containsKey('muted'), isFalse);
      expect(muted.toJson()['muted'], isTrue); // still saved on the phone
      final restored = muted.restoredFrom({
        'cameraDistances': [400],
        'muted': false,
      });
      expect(restored.muted, isTrue);
      expect(restored.cameraDistances, [400]);
    },
  );

  test('standing still right at a camera: no endless "0 m" warning', () async {
    // About the banner, not the sound (no audio in unit tests).
    final app = AppController(storage: _MemoryStorage(), voice: _SilentVoice());
    await app.addPoint(_point);
    var t = DateTime(2026, 1, 1);
    // Drive north towards it.
    for (var m = 400.0; m >= 20; m -= 10) {
      final (lat, lng) = destinationPoint(_point.lat, _point.lng, 180, m);
      app.debugGpsFix(
        DriveSample(lat: lat, lng: lng, speedMps: 10, heading: 0, time: t),
      );
      t = t.add(const Duration(seconds: 1));
    }
    expect(app.active?.point.id, 'p1');
    // Parked right there: the banner goes away.
    final (lat, lng) = destinationPoint(_point.lat, _point.lng, 180, 5);
    app.debugGpsFix(
      DriveSample(lat: lat, lng: lng, speedMps: 0, time: t, stationary: true),
    );
    expect(app.active, isNull);
  });
}
