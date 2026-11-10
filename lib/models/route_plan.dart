import 'dart:math' as math;

import '../utils/geo.dart';
import 'speed_point.dart';
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
    this.located = true,
    this.distanceM,
  });

  /// OpenStreetMap: "N123", "W45"... Google: "g:" + its place id.
  final String id;
  final String name;

  /// Where it is, e.g. "Duhok, Iraq".
  final String address;
  final double lat;
  final double lng;

  /// What it is: city, road, mall, restaurant, fuel...
  final String kind;

  /// False for a search result without its spot yet (Google): [lat] and
  /// [lng] are 0 until [AppController.resolvePlace] looks it up.
  final bool located;

  /// Straight-line meters from the driver, when search said.
  final double? distanceM;

  bool get fromGoogle => id.startsWith('g:');

  /// This place at [spot]'s position (name and address kept when known).
  Place locatedAt(Place spot) => Place(
    id: id,
    name: name.isNotEmpty ? name : spot.name,
    address: address.isNotEmpty ? address : spot.address,
    lat: spot.lat,
    lng: spot.lng,
    kind: kind != 'place' ? kind : spot.kind,
  );

  factory Place.fromJson(Map<String, dynamic> json) {
    final lat = (json['lat'] as num?)?.toDouble();
    final lng = (json['lng'] as num?)?.toDouble();
    return Place(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      address: json['address'] as String? ?? '',
      lat: lat ?? 0,
      lng: lng ?? 0,
      kind: json['kind'] as String? ?? 'place',
      located: lat != null && lng != null,
      distanceM: (json['distanceM'] as num?)?.toDouble(),
    );
  }

  /// For recent searches. Google's terms say not to keep its coordinates,
  /// so a Google place is looked up again when picked.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    if (located && !fromGoogle) ...{'lat': lat, 'lng': lng},
    'kind': kind,
  };
}

/// One turn-by-turn instruction ("Turn left onto Zakho Road").
class RouteStep {
  const RouteStep({
    required this.instruction,
    required this.type,
    required this.modifier,
    required this.name,
    required this.distanceM,
    required this.durationS,
    required this.lat,
    required this.lng,
  });

  final String instruction;

  /// depart, turn, fork, merge, roundabout, arrive...
  final String type;

  /// left, slight right, straight, uturn... (may be empty).
  final String modifier;

  /// The road after this step.
  final String name;

  /// How far / long to drive after it, until the next step.
  final int distanceM;
  final int durationS;
  final double lat;
  final double lng;

  factory RouteStep.fromJson(Map<String, dynamic> json) => RouteStep(
    instruction: json['instruction'] as String? ?? '',
    type: json['type'] as String? ?? '',
    modifier: json['modifier'] as String? ?? '',
    name: json['name'] as String? ?? '',
    distanceM: (json['distanceM'] as num?)?.round() ?? 0,
    durationS: (json['durationS'] as num?)?.round() ?? 0,
    lat: (json['lat'] as num?)?.toDouble() ?? 0,
    lng: (json['lng'] as num?)?.toDouble() ?? 0,
  );
}

/// A camera, bump... on a route, and how far along the route it is.
typedef RouteStop = ({SpeedPoint point, double atM});

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
    this.mobiles = 0,
    this.steps = const [],
  }) : _along = _cumulative(path);

  /// Length in meters and normal driving time in seconds.
  final int distanceM;
  final int durationS;

  /// The main roads it uses.
  final String summary;
  final List<({double lat, double lng})> path;

  /// Speed cameras, bumps and police radar reports on this route.
  final int cameras;
  final int bumps;
  final int mobiles;

  /// Turn-by-turn directions.
  final List<RouteStep> steps;

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
    mobiles: (json['mobiles'] as num?)?.round() ?? 0,
    pointIds: (json['pointIds'] as List? ?? const []).cast<String>(),
    steps: [
      for (final st
          in (json['steps'] as List? ?? const []).cast<Map<String, dynamic>>())
        RouteStep.fromJson(st),
    ],
  );

  /// The points of [pointIds] found in [points], in the order you reach
  /// them, with the distance from the start to each.
  List<RouteStop> stopsFrom(Iterable<SpeedPoint> points) {
    final ids = pointIds.toSet();
    final total = _along.isEmpty ? 0.0 : _along.last;
    final stops = <RouteStop>[
      for (final p in points)
        if (p.remoteId != null && ids.contains(p.remoteId))
          (
            point: p,
            atM: (total - progress(p.lat, p.lng).remainingM)
                .clamp(0, total)
                .toDouble(),
          ),
    ]..sort((a, b) => a.atM.compareTo(b.atM));
    return stops;
  }

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
