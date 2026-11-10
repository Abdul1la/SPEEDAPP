import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/speed_point.dart';
import '../utils/geo.dart';

/// The most pins put on the map at once. Thousands of markers make the map
/// itself slow (on Android especially), and nobody reads more than this.
const maxPins = 400;

/// The pins worth drawing: those on screen (plus half a screen around it,
/// so panning shows them at once) and those near the car, at most [max],
/// nearest first. Warnings don't depend on this; they check every point.
List<SpeedPoint> pinsToShow(
  List<SpeedPoint> all, {
  LatLngBounds? view,
  double? carLat,
  double? carLng,
  double carRadiusM = 3000,
  int max = maxPins,
}) {
  final car = carLat != null && carLng != null;
  if (view == null && !car) {
    return all.length <= max ? all : all.sublist(0, max);
  }

  // The screen, grown by half its size on every side.
  double? south, north, west, east;
  if (view != null) {
    final dLat = (view.northeast.latitude - view.southwest.latitude).abs();
    final dLng = (view.northeast.longitude - view.southwest.longitude).abs();
    south = view.southwest.latitude - dLat / 2;
    north = view.northeast.latitude + dLat / 2;
    west = view.southwest.longitude - dLng / 2;
    east = view.northeast.longitude + dLng / 2;
  }
  // A box around the car (cheaper than a distance for every point).
  final carDLat = carRadiusM / 111320;
  final carDLng = car
      ? carDLat / math.max(0.2, math.cos(carLat * math.pi / 180))
      : 0.0;

  final shown = <SpeedPoint>[
    for (final p in all)
      if ((view != null &&
              p.lat >= south! &&
              p.lat <= north! &&
              p.lng >= west! &&
              p.lng <= east!) ||
          (car &&
              (p.lat - carLat).abs() <= carDLat &&
              (p.lng - carLng).abs() <= carDLng))
        p,
  ];
  if (shown.length <= max) return shown;

  // Too many (zoomed far out): the nearest to the car, or the middle.
  final cLat = car
      ? carLat
      : (view!.northeast.latitude + view.southwest.latitude) / 2;
  final cLng = car
      ? carLng
      : (view!.northeast.longitude + view.southwest.longitude) / 2;
  final byDistance = [
    for (final p in shown) (p, distanceMeters(cLat, cLng, p.lat, p.lng)),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final e in byDistance.take(max)) e.$1];
}
