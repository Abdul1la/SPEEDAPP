import 'dart:math' as math;

const double _earthRadius = 6371000.0; // meters

double _rad(double deg) => deg * math.pi / 180.0;
double _deg(double rad) => rad * 180.0 / math.pi;

/// Great-circle distance between two coordinates, in meters.
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * _earthRadius * math.asin(math.min(1.0, math.sqrt(a)));
}

/// Compass bearing (0..360, 0 = north) from point 1 to point 2.
double bearingDegrees(double lat1, double lng1, double lat2, double lng2) {
  final p1 = _rad(lat1);
  final p2 = _rad(lat2);
  final dLng = _rad(lng2 - lng1);
  final y = math.sin(dLng) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) -
      math.sin(p1) * math.cos(p2) * math.cos(dLng);
  return normalizeDegrees(_deg(math.atan2(y, x)));
}

/// Smallest angle between two compass headings (0..180).
double angleDifference(double a, double b) {
  final d = (normalizeDegrees(a) - normalizeDegrees(b)).abs();
  return d > 180 ? 360 - d : d;
}

double normalizeDegrees(double d) {
  final r = d % 360;
  return r < 0 ? r + 360 : r;
}

/// The coordinate reached by travelling [meters] from a start point along
/// [bearing]. Returns (lat, lng).
(double, double) destinationPoint(
  double lat,
  double lng,
  double bearing,
  double meters,
) {
  final delta = meters / _earthRadius;
  final theta = _rad(bearing);
  final p1 = _rad(lat);
  final l1 = _rad(lng);
  final p2 = math.asin(
    math.sin(p1) * math.cos(delta) +
        math.cos(p1) * math.sin(delta) * math.cos(theta),
  );
  final l2 =
      l1 +
      math.atan2(
        math.sin(theta) * math.sin(delta) * math.cos(p1),
        math.cos(delta) - math.sin(p1) * math.sin(p2),
      );
  return (_deg(p2), ((_deg(l2) + 540) % 360) - 180);
}

/// Human readable compass direction, e.g. 92 -> "E".
String compassName(double degrees) {
  const names = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  return names[((normalizeDegrees(degrees) + 22.5) ~/ 45) % 8];
}
