import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/models/custom_sound.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/services/sound_resolver.dart';

const mine = CustomSound(file: 'a.mp3', name: 'My camera.mp3');
const mine300 = CustomSound(file: 'b.mp4', name: 'Clip 300.mp4');
const pointOwn = CustomSound(file: 'c.m4a', name: 'Bridge camera.m4a');

ResolvedSound resolve({
  List<String> slots = const ['camera_300', 'camera'],
  CustomSound? own,
  Map<String, CustomSound> user = const {},
  Set<String> files = const {'a.mp3', 'b.mp4', 'c.m4a'},
  Set<String> assets = const {},
}) => resolveSound(
  slots: slots,
  own: own,
  userSounds: user,
  fileExists: (s) => files.contains(s.file),
  assetFor: (slot) => assets.contains(slot) ? 'assets/sounds/$slot.mp3' : null,
);

void main() {
  test('slot names match the built-in file names', () {
    expect(SoundSlot.type(PointType.camera), 'camera');
    expect(SoundSlot.distance(PointType.bump, 100), 'bump_100');
    expect(SoundSlot.forApproach(PointType.camera, 300), [
      'camera_300',
      'camera',
    ]);
  });

  test('phone voice when nothing is set', () {
    expect(resolve().origin, SoundOrigin.phoneVoice);
  });

  test('the point\'s own sound wins over everything', () {
    final r = resolve(
      own: pointOwn,
      user: {'camera_300': mine300, 'camera': mine},
      assets: {'camera_300'},
    );
    expect(r.origin, SoundOrigin.point);
    expect(r.custom, pointOwn);
  });

  test('your sound for one distance wins over your sound for all', () {
    final r = resolve(user: {'camera_300': mine300, 'camera': mine});
    expect(r.origin, SoundOrigin.custom);
    expect(r.custom, mine300);
  });

  test('your sound for all distances wins over a built-in recording', () {
    final r = resolve(user: {'camera': mine}, assets: {'camera_300'});
    expect(r.origin, SoundOrigin.custom);
    expect(r.custom, mine);
  });

  test('built-in recording for the distance, then for the type', () {
    expect(
      resolve(assets: {'camera_300', 'camera'}).asset,
      'assets/sounds/camera_300.mp3',
    );
    expect(resolve(assets: {'camera'}).asset, 'assets/sounds/camera.mp3');
  });

  test('missing files are skipped (e.g. points from another phone)', () {
    final r = resolve(own: pointOwn, user: {'camera': mine}, files: {'a.mp3'});
    expect(r.origin, SoundOrigin.custom);
    expect(r.custom, mine);
  });

  group('CustomSound', () {
    test('JSON round trip', () {
      const s = CustomSound(file: 'x.mov', name: 'Beep.MOV', durationMs: 2300);
      expect(CustomSound.fromJson(s.toJson()), s);
    });

    test('broken JSON gives null instead of crashing', () {
      expect(CustomSound.fromJson(null), isNull);
      expect(CustomSound.fromJson('x'), isNull);
      expect(CustomSound.fromJson({'name': 'no file'}), isNull);
      expect(CustomSound.fromJson({'file': ''}), isNull);
    });

    test('knows video files by extension', () {
      expect(const CustomSound(file: 'a', name: 'clip.MP4').isVideo, isTrue);
      expect(const CustomSound(file: 'a', name: 'beep.mp3').isVideo, isFalse);
      expect(const CustomSound(file: 'a', name: 'noext').isVideo, isFalse);
    });

    test('clip length text', () {
      expect(formatClipLength(const Duration(seconds: 7)), '0:07');
      expect(formatClipLength(const Duration(seconds: 83)), '1:23');
    });
  });
}
