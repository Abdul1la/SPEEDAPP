import 'dart:math' as math;

import '../models/app_settings.dart';
import '../models/speed_point.dart';
import '../utils/geo.dart';

/// One GPS reading (real or simulated).
class DriveSample {
  const DriveSample({
    required this.lat,
    required this.lng,
    required this.speedMps,
    required this.time,
    this.heading,
  });

  final double lat;
  final double lng;

  /// Speed in meters per second (0 if unknown).
  final double speedMps;

  /// Direction of travel reported by the GPS (0..360), if valid.
  final double? heading;
  final DateTime time;

  double get speedKmh => math.max(0, speedMps) * 3.6;
}

enum AlertEventKind { approach, overSpeed }

/// Something that should be spoken right now.
class AlertEvent {
  const AlertEvent(this.kind, this.point, {this.distance = 0});

  final AlertEventKind kind;
  final SpeedPoint point;

  /// For [AlertEventKind.approach]: the warning distance that was reached
  /// (e.g. 300), not the exact distance.
  final int distance;

  @override
  String toString() => '${kind.name}(${point.id}, $distance)';
}

/// The point currently shown in the warning banner.
class ActiveAlert {
  const ActiveAlert({
    required this.point,
    required this.distance,
    required this.overLimit,
  });

  final SpeedPoint point;
  final double distance;
  final bool overLimit;
}

/// A point further up the road (not warning yet).
class Upcoming {
  const Upcoming(this.point, this.distance);
  final SpeedPoint point;
  final double distance;
}

class AlertResult {
  const AlertResult(this.events, this.active);
  final List<AlertEvent> events;
  final ActiveAlert? active;
}

class _PointState {
  final Set<int> announced = {};
  double minDistance = double.infinity;
  bool passed = false;

  /// Farthest we got after passing it (to notice a U-turn back to it).
  double maxAfterPass = 0;
  DateTime? lastOverSpeed;
}

/// Decides when to warn. Pure logic, no Flutter, so it is easy to test.
///
/// For every point near the driver it checks:
///  * is it in front of us (not behind, not off to the side)?
///  * does it apply to our travel direction (if the point has one)?
///  * which warning distance (500/300/200/100 m...) did we just cross?
/// Each distance is announced only once per approach. After the driver
/// passes the point and moves away, it is reset so the next approach
/// warns again.
class AlertEngine {
  /// A point counts as "ahead" if it is within this angle of our course.
  static const double aheadAngle = 60;

  /// A point is clearly behind us beyond this angle.
  static const double behindAngle = 100;

  /// How close our course must be to a point's direction to match it.
  static const double directionAngle = 50;

  /// Extra distance past the farthest warning before a point is reset.
  static const double resetMargin = 150;

  /// Distance must grow this much past the closest approach to count as
  /// passed (keeps GPS jitter from triggering it).
  static const double passedMargin = 30;

  /// Inside this range the bearing to the point is too noisy to trust.
  static const double closeRange = 40;

  static const Duration overSpeedRepeat = Duration(seconds: 10);
  static const double _minSpeedForGpsHeading = 1.5; // m/s
  static const double _courseFixDistance = 15; // m

  final Map<String, _PointState> _states = {};
  double? _course;
  double? _anchorLat;
  double? _anchorLng;

  /// Our current direction of travel, if known.
  double? get course => _course;

  void reset() {
    _states.clear();
    _course = null;
    _anchorLat = null;
    _anchorLng = null;
  }

  AlertResult update(
    DriveSample s,
    Iterable<SpeedPoint> points,
    AppSettings settings,
  ) {
    _updateCourse(s);

    final events = <AlertEvent>[];
    final inRange = <String>{};
    SpeedPoint? bestPoint;
    double bestDistance = double.infinity;

    for (final p in points) {
      final thresholds = settings.distancesFor(p.type);
      if (thresholds.isEmpty) continue;
      final farthest = thresholds.first.toDouble();
      final range = farthest + resetMargin;

      // Cheap rejection before the real distance math.
      if ((p.lat - s.lat).abs() * 111000 > range) continue;
      final d = distanceMeters(s.lat, s.lng, p.lat, p.lng);
      if (d > range) continue;

      inRange.add(p.id);
      var st = _states.putIfAbsent(p.id, _PointState.new);
      if (st.passed) {
        // Turned around and coming back to it (a point for both ways, or
        // for this direction): that's a new approach, warn again.
        st.maxAfterPass = math.max(st.maxAfterPass, d);
        final off = _offAngle(s, p, d);
        final comingBack =
            off != null &&
            off <= aheadAngle &&
            d < st.maxAfterPass - 2 * passedMargin &&
            _directionMatches(p);
        if (!comingBack) continue;
        st = _states[p.id] = _PointState();
      }

      final engaged = st.announced.isNotEmpty;
      final offAngle = _offAngle(s, p, d);

      if (engaged) {
        final movingAway = d > st.minDistance + passedMargin;
        final behind = offAngle != null && offAngle > behindAngle;
        if (movingAway || behind) {
          st.passed = true;
          continue;
        }
        st.minDistance = math.min(st.minDistance, d);
      } else {
        st.minDistance = d;
      }

      final ahead = offAngle == null || offAngle <= aheadAngle;
      if (!ahead || !_directionMatches(p)) continue;

      final crossed = thresholds.where((t) => d <= t).toList();
      if (crossed.isEmpty) continue;

      final nearest = crossed.last; // thresholds are sorted far -> near
      if (!st.announced.contains(nearest)) {
        events.add(AlertEvent(AlertEventKind.approach, p, distance: nearest));
      }
      st.announced.addAll(crossed);

      if (d < bestDistance) {
        bestDistance = d;
        bestPoint = p;
      }
    }

    // Forget points we have left behind, so they warn again next time.
    _states.removeWhere((id, _) => !inRange.contains(id));

    ActiveAlert? active;
    if (bestPoint != null) {
      final limit = bestPoint.speedLimit;
      final over =
          limit != null && s.speedKmh > limit + settings.overSpeedTolerance;
      if (over) {
        final st = _states[bestPoint.id]!;
        final last = st.lastOverSpeed;
        if (last == null || s.time.difference(last) >= overSpeedRepeat) {
          st.lastOverSpeed = s.time;
          events.add(AlertEvent(AlertEventKind.overSpeed, bestPoint));
        }
      }
      active = ActiveAlert(
        point: bestPoint,
        distance: bestDistance,
        overLimit: over,
      );
    }

    return AlertResult(events, active);
  }

  /// The closest point in front of us on our direction, up to
  /// [maxDistance] meters away (for the "next on your road" display).
  /// Call after [update] so the course is current.
  Upcoming? nextAhead(
    DriveSample s,
    Iterable<SpeedPoint> points, {
    double maxDistance = 10000,
  }) {
    final c = _course;
    SpeedPoint? best;
    var bestD = maxDistance;
    for (final p in points) {
      if ((p.lat - s.lat).abs() * 111000 > bestD) continue;
      final d = distanceMeters(s.lat, s.lng, p.lat, p.lng);
      if (d > bestD) continue;
      if (c != null && d >= closeRange) {
        final off = angleDifference(
          c,
          bearingDegrees(s.lat, s.lng, p.lat, p.lng),
        );
        if (off > 45) continue;
      }
      if (_states[p.id]?.passed ?? false) continue;
      if (!_directionMatches(p)) continue;
      best = p;
      bestD = d;
    }
    return best == null ? null : Upcoming(best, bestD);
  }

  /// Angle between our course and the direction to the point, or null when
  /// we can't tell (no course yet, or we are right on top of it).
  double? _offAngle(DriveSample s, SpeedPoint p, double d) {
    final c = _course;
    if (c == null || d < closeRange) return null;
    return angleDifference(c, bearingDegrees(s.lat, s.lng, p.lat, p.lng));
  }

  bool _directionMatches(SpeedPoint p) {
    final dir = p.direction;
    final c = _course;
    if (dir == null || c == null) return true;
    return angleDifference(c, dir) <= directionAngle;
  }

  void _updateCourse(DriveSample s) {
    final h = s.heading;
    if (h != null && h >= 0 && s.speedMps >= _minSpeedForGpsHeading) {
      _course = normalizeDegrees(h);
      _anchorLat = s.lat;
      _anchorLng = s.lng;
      return;
    }
    // GPS heading not usable: work it out from how we moved.
    if (_anchorLat == null || _anchorLng == null) {
      _anchorLat = s.lat;
      _anchorLng = s.lng;
      return;
    }
    final moved = distanceMeters(_anchorLat!, _anchorLng!, s.lat, s.lng);
    if (moved >= _courseFixDistance) {
      _course = bearingDegrees(_anchorLat!, _anchorLng!, s.lat, s.lng);
      _anchorLat = s.lat;
      _anchorLng = s.lng;
    }
  }
}
