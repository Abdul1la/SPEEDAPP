import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/models/app_settings.dart';
import 'package:new_project/models/custom_sound.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/models/warning_tone.dart';
import 'package:new_project/services/storage.dart';

const clip = CustomSound(
  file: 'sound_1.mp4',
  name: 'Beep.mp4',
  durationMs: 2100,
);
const voice = CustomSound(file: 'sound_2.m4a', name: 'Camera.m4a');

/// Saves and loads like the app does (through JSON text).
AppSettings roundTrip(AppSettings s) => AppSettings.fromJson(
  jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
);

void main() {
  group('AppSettings sounds', () {
    test('default: no sounds, every warning plays once', () {
      const s = AppSettings();
      expect(s.sounds, isEmpty);
      expect(s.repeatFor('camera'), 1);
      expect(s.repeatFor('over_speed'), 1);
    });

    test('set and remove a sound', () {
      final s = const AppSettings().withSound('camera', clip);
      expect(s.sounds['camera'], clip);
      expect(s.withSound('camera', null).sounds, isEmpty);
    });

    test('repeat is kept between 1 and the max', () {
      const s = AppSettings();
      expect(s.withRepeat('bump', 3).repeatFor('bump'), 3);
      expect(s.withRepeat('bump', 0).repeatFor('bump'), 1);
      expect(s.withRepeat('bump', 99).repeatFor('bump'), maxRepeat);
    });

    test('sounds and repeats survive saving and loading', () {
      final s = const AppSettings()
          .withSound('camera', clip)
          .withSound('bump_100', voice)
          .withRepeat('camera', 2)
          .withRepeat('over_speed', 4);
      final back = roundTrip(s);
      expect(back.sounds, {'camera': clip, 'bump_100': voice});
      expect(back.repeatFor('camera'), 2);
      expect(back.repeatFor('over_speed'), 4);
      expect(back.repeatFor('bump'), 1);
    });

    test('settings saved before this feature still load', () {
      final old = AppSettings.fromJson({
        'cameraDistances': [400, 100],
        'muted': true,
      });
      expect(old.sounds, isEmpty);
      expect(old.repeatFor('camera'), 1);
      expect(old.cameraDistances, [400, 100]);
    });

    test('broken sound data is ignored', () {
      final s = AppSettings.fromJson({
        'sounds': {
          'camera': 'nope',
          'bump': {'file': 'ok.mp3'},
        },
        'repeats': {'camera': 'x', 'bump': 7},
      });
      expect(s.sounds.keys, ['bump']);
      expect(s.repeatFor('camera'), 1);
      expect(s.repeatFor('bump'), maxRepeat);
    });
  });

  group('Built-in sounds', () {
    test('default: Chime for cameras, Bump-bump for bumps, then the voice', () {
      const s = AppSettings();
      expect(s.toneFor(PointType.camera), WarningTone.chime);
      expect(s.toneFor(PointType.bump), WarningTone.bump);
      expect(s.speakDistance, isTrue);
    });

    test('choose a sound, or the phone voice only', () {
      final s = const AppSettings()
          .withTone(PointType.camera, WarningTone.alert)
          .withTone(PointType.bump, null);
      expect(s.toneFor(PointType.camera), WarningTone.alert);
      expect(s.toneFor(PointType.bump), isNull);
    });

    test('saved, loaded and backed up to the account', () {
      final s = const AppSettings()
          .withTone(PointType.camera, WarningTone.radar)
          .withTone(PointType.bump, null)
          .copyWith(speakDistance: false);
      final back = roundTrip(s);
      expect(back.toneFor(PointType.camera), WarningTone.radar);
      expect(back.toneFor(PointType.bump), isNull);
      expect(back.speakDistance, isFalse);

      final restored = const AppSettings().restoredFrom(
        jsonDecode(jsonEncode(s.toBackupJson())) as Map<String, dynamic>,
      );
      expect(restored.toneFor(PointType.camera), WarningTone.radar);
      expect(restored.speakDistance, isFalse);
    });

    test('unknown saved sounds fall back to the default', () {
      final s = AppSettings.fromJson({
        'tones': {'camera': 'trumpet', 'bump': 42},
        'speakDistance': 'yes',
      });
      expect(s.toneFor(PointType.camera), WarningTone.chime);
      expect(s.toneFor(PointType.bump), WarningTone.bump);
      expect(s.speakDistance, isTrue);
    });

    test('every built-in sound file is in the app', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/sounds/tones/'));
      for (final t in WarningTone.values) {
        expect(File(t.asset).existsSync(), isTrue, reason: t.asset);
      }
    });
  });

  group('SpeedPoint own sound', () {
    const p = SpeedPoint(
      id: 'p1',
      type: PointType.camera,
      lat: 33.3,
      lng: 44.4,
      sound: voice,
      repeat: 3,
    );

    test('survives export and import', () {
      final back = parsePoints(exportPoints([p])).single;
      expect(back.sound, voice);
      expect(back.repeat, 3);
    });

    test('copyWith can clear it, and keeps it otherwise', () {
      expect(p.copyWith(note: () => 'x').sound, voice);
      final cleared = p.copyWith(sound: () => null, repeat: () => null);
      expect(cleared.sound, isNull);
      expect(cleared.repeat, isNull);
    });

    test('moving a point keeps its sound', () {
      final moved = p.copyWith(lat: 33.4, lng: 44.5);
      expect(moved.sound, voice);
      expect(moved.repeat, 3);
    });

    test('withId keeps the sound', () {
      expect(p.withId('p2').sound, voice);
    });

    test('points without a sound are saved without one', () {
      const plain = SpeedPoint(id: 'p3', type: PointType.bump, lat: 1, lng: 2);
      expect(plain.toJson().containsKey('sound'), isFalse);
      expect(plain.toJson().containsKey('repeat'), isFalse);
    });
  });
}
