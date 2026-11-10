import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:new_project/map/visible_pins.dart';
import 'package:new_project/models/custom_sound.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/services/storage.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

SpeedPoint _at(String id, double lat, double lng, {bool community = true}) =>
    SpeedPoint(
      id: id,
      type: PointType.camera,
      lat: lat,
      lng: lng,
      speedLimit: 80,
      community: community,
      remoteId: community ? 'r$id' : null,
      createdAt: DateTime.utc(2026, 11, 10),
      sound: id == '0'
          ? const CustomSound(file: 'a.mp3', name: 'A', durationMs: 900)
          : null,
    );

void main() {
  group('only the pins worth drawing', () {
    // Duhok, and points every ~1.1 km to the north.
    const lat = 36.8669, lng = 42.9885;
    final line = [for (var i = 0; i < 200; i++) _at('$i', lat + i * 0.01, lng)];

    test('on screen (with a margin) and near the car', () {
      final view = LatLngBounds(
        southwest: const LatLng(lat + 0.995, lng - 0.01),
        northeast: const LatLng(lat + 1.045, lng + 0.01),
      );
      final shown = pinsToShow(line, view: view, carLat: lat, carLng: lng);
      final ids = shown.map((p) => int.parse(p.id)).toSet();
      // Near the car (3 km): 0..2. On screen 100..104, plus half a screen
      // around it (≈ 2.5 km each way): 97..107.
      expect(ids.containsAll([0, 1, 2]), isTrue);
      expect(ids.containsAll([97, 100, 104, 107]), isTrue);
      expect(ids.contains(50), isFalse);
      expect(ids.contains(150), isFalse);
      expect(shown.length, lessThan(20));
    });

    test('zoomed far out: at most maxPins, nearest to the car first', () {
      final many = [
        for (var i = 0; i < 2000; i++)
          _at('$i', lat + (i % 50) * 0.002, lng + (i ~/ 50) * 0.002),
      ];
      final world = LatLngBounds(
        southwest: const LatLng(30, 38),
        northeast: const LatLng(38, 49),
      );
      final shown = pinsToShow(many, view: world, carLat: lat, carLng: lng);
      expect(shown, hasLength(maxPins));
      expect(shown.first.id, '0'); // right at the car
      expect(shown.any((p) => p.id == '1999'), isFalse); // the farthest
    });

    test('no screen and no car yet: the list as it is, capped', () {
      expect(pinsToShow(line.take(10).toList()), hasLength(10));
      expect(pinsToShow(line, max: 50), hasLength(50));
    });
  });

  test(
    'big point lists are saved and read back (off the main thread)',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final storage = Storage();
      final points = [
        for (var i = 0; i < 3000; i++)
          _at('$i', 36.8 + i * 0.0001, 42.9 + i * 0.0001),
      ];
      await storage.saveCommunity(points);
      final back = await storage.loadCommunity();
      expect(back, hasLength(3000));
      expect(back.first.sound?.name, 'A');
      expect(back.last.lat, closeTo(points.last.lat, 1e-9));

      final mine = [
        for (var i = 0; i < 600; i++)
          _at('m$i', 36.8 + i * 0.001, 42.9, community: false),
      ];
      await storage.savePoints(mine);
      expect(await storage.loadPoints(), hasLength(600));
      // Small lists take the quick path; same result.
      await storage.saveCommunity(points.take(3).toList());
      expect(await storage.loadCommunity(), hasLength(3));
    },
  );
}
