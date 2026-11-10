import 'dart:math' as math;

import '../utils/geo.dart';
import '../utils/polyline.dart';

/// A place found by search ("Duhok", a street, a shop...).
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.address,
    required this.lat,
    required this.lng,
    this.kind = 'place',
  });

  final String id;
  final String name;

  /// Where it is, e.g. "Duhok, Iraq".
  final String address;
  final double lat;
  final double lng;

  /// What it is: city, town, road, school, shop...
  final String kind;

  factory Place.fromJson(Map<String, dynamic> json) => Place(
    id: json['id'] as String,
    name: json['name'] as String,
    address: json['address'] as String? ?? '',
    lat: (json['lat'] as num).toDouble(),
    lng: (json['lng'] as num).toDouble(),
    kind: json['kind'] as String? ?? 'place',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'lat': lat,
    'lng': lng,
    'kind': kind,
  };
}

/// One way to drive to the destination.
class RouteOption {
  RouteOption({
    required this.distanceM,
    required this.durationS,
    required this.summary,
    required this.path,
    required this.cameras,
    required this.bumps,
    required this.pointIds,
  }) : _along = _cumulative(path);

  /// Length in meters and normal driving time in seconds.
  final int distanceM;
  final int durationS;

  /// The main roads it uses.
  final String summary;
  final List<({double lat, double lng})> path;

  /// Speed cameras and bumps on this route.
  final int cameras;
  final int bumps;

  /// Server ids of those points.
  final List<String> pointIds;

  /// Meters from the start to each point of [path].
  final List<double> _along;

  factory RouteOption.fromJson(Map<String, dynamic> json) => RouteOption(
    distanceM: (json['distanceM'] as num).round(),
    durationS: (json['durationS'] as num).round(),
    summary: json['summary'] as String? ?? '',
    path: decodePolyline(json['polyline'] as String),
    cameras: (json['cameras'] as num?)?.round() ?? 0,
    bumps: (json['bumps'] as num?)?.round() ?? 0,
    pointIds: (json['pointIds'] as List? ?? const []).cast<String>(),
  );

  static List<double> _cumulative(List<({double lat, double lng})> path) {
    final out = <double>[0];
    for (var i = 1; i < path.length; i++) {
      final a = path[i - 1];
      final b = path[i];
      out.add(out.last + distanceMeters(a.lat, a.lng, b.lat, b.lng));
    }
    return out;
  }

  /// Where a position is on this route: meters still to drive, and how far
  /// it is from the route line. [hint] (the last index found) makes it fast.
  ({double remainingM, double offRouteM, int index}) progress(
    double lat,
    double lng, {
    int hint = 0,
  }) {
    if (path.length < 2) {
      final d = path.isEmpty
          ? 0.0
          : distanceMeters(lat, lng, path.first.lat, path.first.lng);
      return (remainingM: d, offRouteM: d, index: 0);
    }
    // Look near the last match first; fall back to the whole route.
    final windows = [(hint - 30).clamp(0, path.length - 2), 0];
    var best = double.infinity;
    var bestIndex = 0;
    var bestT = 0.0;
    for (final start in windows) {
      final end = start == 0
          ? path.length - 1
          : (hint + 300).clamp(0, path.length - 1);
      for (var i = start; i < end; i++) {
        final (d, t) = _toSegment(lat, lng, path[i], path[i + 1]);
        if (d < best) {
          best = d;
          bestIndex = i;
          bestT = t;
        }
      }
      if (best < 60) break; // found nearby: no need to scan everything
    }
    final segment = _along[bestIndex + 1] - _along[bestIndex];
    final done = _along[bestIndex] + segment * bestT;
    return (
      remainingM: (_along.last - done).clamp(0, double.infinity).toDouble(),
      offRouteM: best,
      index: bestIndex,
    );
  }

  /// Distance in meters from (lat, lng) to the segment a-b, and where along
  /// it (0..1) the closest spot is.
  static (double, double) _toSegment(
    double lat,
    double lng,
    ({double lat, double lng}) a,
    ({double lat, double lng}) b,
  ) {
    const mPerDeg = 111320.0;
    final k = mPerDeg * _cos(lat);
    final ax = (a.lng - lng) * k;
    final ay = (a.lat - lat) * mPerDeg;
    final bx = (b.lng - lng) * k;
    final by = (b.lat - lat) * mPerDeg;
    final dx = bx - ax;
    final dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
    final x = ax + t * dx;
    final y = ay + t * dy;
    return (_sqrt(x * x + y * y), t);
  }
}

double _cos(double deg) => math.cos(deg * math.pi / 180);
double _sqrt(double v) => math.sqrt(v);

/// Routes to one place, fastest first.
class RoutePlan {
  const RoutePlan({
    required this.destination,
    required this.routes,
    required this.points,
  });

  final Place destination;
  final List<RouteOption> routes;

  /// Server JSON of every camera and bump on any of the routes.
  final List<Map<String, dynamic>> points;
}
