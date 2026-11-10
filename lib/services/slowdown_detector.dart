import '../utils/geo.dart';
import 'alert_engine.dart';

/// The driver suddenly slowed down on a fast road without stopping, then
/// sped up again: how drivers react to a police radar. The server puts a
/// police radar on the map when several drivers do this at the same new
/// spot (see backend/src/services/slowdowns.ts).
class Slowdown {
  const Slowdown({
    required this.lat,
    required this.lng,
    required this.speedBefore,
    required this.speedMin,
    required this.time,
    this.heading,
  });

  /// Where the speed was lowest: drivers brake until they pass the radar.
  final double lat;
  final double lng;
  final double? heading;

  /// km/h.
  final double speedBefore;
  final double speedMin;
  final DateTime time;

  /// What is sent to the server: this spot only, never the route.
  Map<String, dynamic> toJson() => {
    'lat': double.parse(lat.toStringAsFixed(6)),
    'lng': double.parse(lng.toStringAsFixed(6)),
    'heading': heading == null ? null : heading!.round() % 360,
    'speedBefore': speedBefore.round(),
    'speedMin': speedMin.round(),
  };
}

/// Finds [Slowdown]s in the GPS readings ([add] each one):
///  1. cruising: at least [minCruiseKmh] in the last [cruiseWindow];
///  2. braking: [minDropKmh] slower within [maxBrakeTime];
///  3. no stop: never below [minLowestKmh] (a light, a jam or a checkpoint
///     ends in a stop, so it isn't counted);
///  4. speeding up again: [recoverKmh] faster within [maxRecoverTime] (a
///     town's lower limit keeps the speed down, so it isn't counted);
///  5. a straight road: the direction changed less than [maxTurn] (braking
///     for a curve, a turn or a roundabout isn't counted).
class SlowdownDetector {
  static const minCruiseKmh = 60.0;
  static const minDropKmh = 20.0;
  static const minLowestKmh = 20.0;
  static const recoverKmh = 12.0;
  static const maxTurn = 35.0;
  static const cruiseWindow = Duration(seconds: 12);
  static const maxBrakeTime = Duration(seconds: 8);
  static const maxRecoverTime = Duration(seconds: 30);
  static const cooldown = Duration(minutes: 2);

  /// A longer gap between readings (tunnel, GPS lost) starts over.
  static const maxGap = Duration(seconds: 5);

  final List<DriveSample> _recent = [];
  DriveSample? _peak;
  DriveSample? _lowest;
  DateTime? _lastFound;

  void reset() {
    _recent.clear();
    _peak = null;
    _lowest = null;
  }

  /// Returns a [Slowdown] when the reading [s] completes one.
  Slowdown? add(DriveSample s) {
    final last = _recent.isEmpty ? null : _recent.last;
    if (last != null &&
        (s.time.difference(last.time) > maxGap || s.time.isBefore(last.time))) {
      reset();
    }
    _recent
      ..add(s)
      ..removeWhere((x) => s.time.difference(x.time) > cruiseWindow);
    final kmh = s.speedKmh;

    final lowest = _lowest;
    final peak = _peak;
    if (lowest == null || peak == null) {
      _lookForBraking(s);
      return null;
    }

    // Braking: did it stop, take too long, or speed up again?
    if (kmh < minLowestKmh) {
      // A light, a jam or a checkpoint: wait for cruising speed again.
      reset();
      return null;
    }
    if (kmh < lowest.speedKmh) {
      _lowest = s;
      return null;
    }
    if (s.time.difference(lowest.time) > maxRecoverTime) {
      reset();
      return null;
    }
    if (kmh < lowest.speedKmh + recoverKmh) return null;

    // Sped up again: a slowdown, unless the road turned.
    reset();
    final from = peak.heading;
    final to = s.heading;
    if (from != null && to != null && angleDifference(from, to) > maxTurn) {
      return null;
    }
    final found = _lastFound;
    if (found != null && s.time.difference(found) < cooldown) return null;
    _lastFound = s.time;
    return Slowdown(
      lat: lowest.lat,
      lng: lowest.lng,
      heading: lowest.heading ?? from,
      speedBefore: peak.speedKmh,
      speedMin: lowest.speedKmh,
      time: lowest.time,
    );
  }

  /// Cruising, then [minDropKmh] slower within [maxBrakeTime]: braking.
  void _lookForBraking(DriveSample s) {
    DriveSample? peak;
    for (final x in _recent) {
      if (s.time.difference(x.time) <= maxBrakeTime &&
          (peak == null || x.speedKmh > peak.speedKmh)) {
        peak = x;
      }
    }
    if (peak == null ||
        peak.speedKmh < minCruiseKmh ||
        s.speedKmh > peak.speedKmh - minDropKmh ||
        s.speedKmh < minLowestKmh) {
      return;
    }
    _peak = peak;
    _lowest = s;
  }
}
