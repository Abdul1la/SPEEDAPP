import 'package:flutter/animation.dart';

import '../utils/geo.dart';

/// The smallest turn from heading [from] to heading [to], in degrees:
/// negative = left (counter-clockwise), positive = right.
/// 0 -> 270 is -90 (a left turn), 350 -> 10 is +20, 10 -> 350 is -20.
double shortestTurn(double from, double to) {
  final d = (normalizeDegrees(to) - normalizeDegrees(from)) % 360;
  return d > 180 ? d - 360 : d;
}

/// One smooth turn of the car on the map, the short way round.
///
/// The car must not jump to a new direction: the map turns after it more
/// slowly, so a jump followed by the map's turn made a left turn look like
/// a turn to the right. Turning the car smoothly, ahead of the map, makes a
/// left turn look left.
class CarTurn {
  CarTurn(this.from, double to) : by = shortestTurn(from, to);

  /// How long the car takes to turn (the map takes longer, see MapScreen).
  static const duration = Duration(milliseconds: 400);

  final double from;

  /// Degrees to turn: negative = left.
  final double by;

  double get to => normalizeDegrees(from + by);

  /// The car's angle at [t] (0 = start, 1 = done).
  double at(double t) => normalizeDegrees(
    from + by * Curves.easeOutCubic.transform(t.clamp(0.0, 1.0)),
  );
}
