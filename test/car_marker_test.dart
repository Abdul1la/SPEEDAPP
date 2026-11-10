import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:new_project/map/car_turn.dart';
import 'package:new_project/map/marker_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the car picture is bundled, sharp (4x) and points up', () async {
    final data = await rootBundle.load(MarkerIcons.carAsset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final image = (await codec.getNextFrame()).image;
    expect(image.width, MarkerIcons.carSize.width * 4);
    expect(image.height, MarkerIcons.carSize.height * 4);

    // Transparent corners; solid car in the middle.
    final px = (await image.toByteData())!;
    int alpha(int x, int y) => px.getUint8((y * image.width + x) * 4 + 3);
    expect(alpha(0, 0), 0);
    expect(alpha(image.width - 1, image.height - 1), 0);
    expect(alpha(image.width ~/ 2, image.height ~/ 2), 255);
    // The red tail lights are at the back (bottom): the car points up.
    final cx = image.width ~/ 2;
    int channel(int y, int c) => px.getUint8((y * image.width + cx) * 4 + c);
    bool isRed(int y) => channel(y, 0) > channel(y, 1) + 100;
    final solid = [
      for (var y = 0; y < image.height; y++)
        if (alpha(cx, y) == 255) y,
    ];
    expect(solid.reversed.take(4).any(isRed), isTrue, reason: 'back is red');
    expect(solid.take(4).any(isRed), isFalse, reason: 'front is not red');
  });

  test('the map gets the car at its size', () async {
    final icons = MarkerIcons();
    expect(icons.car, isNull);
    expect(await icons.prepare(const [], 3), isTrue);
    final car = icons.car! as BytesMapBitmap;
    expect(car.imagePixelRatio, 4);
    expect(await icons.prepare(const [], 3), isFalse); // cached
  });

  test('turning left turns the car left (the short way round)', () {
    expect(shortestTurn(0, 270), -90); // north -> west: left
    expect(shortestTurn(0, 90), 90); // north -> east: right
    expect(shortestTurn(350, 10), 20); // across north, to the right
    expect(shortestTurn(10, 350), -20); // across north, to the left
    expect(shortestTurn(90, 0), -90); // east -> north: left

    final left = CarTurn(0, 270);
    expect(left.to, 270);
    for (final t in [0.1, 0.3, 0.5, 0.8]) {
      final a = left.at(t);
      // Always on the left side (270..360), never swinging right first.
      expect(a, inInclusiveRange(270, 360), reason: 't=$t angle=$a');
      expect(shortestTurn(0, a), lessThan(0));
    }
    expect(left.at(0), 0);
    expect(left.at(1), 270);
    // Each step moves further left.
    expect(shortestTurn(left.at(0.3), left.at(0.6)), lessThan(0));

    final right = CarTurn(350, 20);
    expect(shortestTurn(350, right.at(0.5)), greaterThan(0));
    expect(right.at(1), closeTo(20, 1e-9));
  });
}
