import 'dart:math' as math;

import '../utils/geo.dart';
import 'alert_engine.dart';

/// Cleans up the speed the phone reports.
///
/// When a phone stands still (parked, at a light, indoors) its GPS position
/// wobbles by several meters and many phones report a made-up speed of
/// 10-30 km/h. This filter shows 0 when the driver isn't really moving:
///  * the phone's own speed accuracy says the speed is noise;
///  * over the last few seconds the position hardly moved (less than the
///    GPS accuracy), whatever speed was reported;
///  * below [stopSpeed] it's walking pace or noise: 0.
/// While stopped the heading is dropped too, so the driving direction (used
/// to know which points are ahead) doesn't spin around.
class SpeedFilter {
  /// Below this (m/s, about 4 km/h) counts as stopped.
  static const stopSpeed = 1.1;

  /// How far back positions are compared.
  static const window = Duration(seconds: 6);

  /// Smallest movement over [window] that counts as moving, in meters
  /// (raised to the GPS accuracy when that is worse).
  static const minMove = 8.0;

  final List<_Fix> _recent = [];

  /// The corrected sample for a raw GPS fix. [accuracyM] is the position
  /// accuracy and [speedAccuracyMps] the speed accuracy (0 = unknown).
  DriveSample add(
    DriveSample raw, {
    double accuracyM = 0,
    double speedAccuracyMps = 0,
  }) {
    _recent
      ..add(_Fix(raw.lat, raw.lng, raw.time, accuracyM))
      ..removeWhere((f) => raw.time.difference(f.time) > window);

    var speed = raw.speedMps; // 0 or less = the phone doesn't know
    final moved = _movement();

    // No speed from the phone: use how far we moved.
    if (speed <= 0 && moved != null) speed = moved.speed;

    // The phone itself says the number is mostly noise: 0, unless the
    // position clearly moved (weak signal between buildings while driving
    // slowly), and then the movement is the speed.
    if (speedAccuracyMps > 0 && speed < 2 * speedAccuracyMps) {
      final clearlyMoving =
          moved != null &&
          moved.distance >= 2 * math.max(minMove, moved.accuracy);
      speed = clearlyMoving ? moved.speed : 0;
    }

    // Hardly moved over the last seconds: standing still.
    if (moved != null && moved.distance < math.max(minMove, moved.accuracy)) {
      speed = 0;
    }

    if (speed < stopSpeed) speed = 0;

    if (speed == raw.speedMps && speed > 0) return raw;
    return DriveSample(
      lat: raw.lat,
      lng: raw.lng,
      speedMps: speed,
      heading: speed > 0 ? raw.heading : null,
      time: raw.time,
      stationary: speed == 0,
    );
  }

  /// Net movement over the window (null until there are 3+ seconds of fixes).
  _Movement? _movement() {
    if (_recent.length < 2) return null;
    final first = _recent.first;
    final last = _recent.last;
    final seconds = last.time.difference(first.time).inMilliseconds / 1000;
    if (seconds < 3) return null;
    final d = distanceMeters(first.lat, first.lng, last.lat, last.lng);
    final accuracy = _recent.map((f) => f.accuracy).fold<double>(0, math.max);
    return _Movement(d, d / seconds, accuracy);
  }
}

class _Fix {
  const _Fix(this.lat, this.lng, this.time, this.accuracy);
  final double lat;
  final double lng;
  final DateTime time;
  final double accuracy;
}

class _Movement {
  const _Movement(this.distance, this.speed, this.accuracy);
  final double distance;
  final double speed;
  final double accuracy;
}
