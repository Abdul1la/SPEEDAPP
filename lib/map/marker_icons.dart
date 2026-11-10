import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/speed_point.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';

/// Draws our own map pins (camera / speed bump / car) in code, so there
/// are no image files to manage. Edit the paint code to change the look.
///
/// Flat design: colored circle with a white ring, a short pointer to the
/// exact spot, and a small speed-limit sign when the point has a limit.
class MarkerIcons {
  static const _w = 52.0;
  static const _h = 58.0;
  static const _headX = 24.0;
  static const _head = Offset(_headX, 24);
  static const _headR = 17.0;
  static const _tipY = 50.0;

  /// Where the pin touches the map (tip of the pointer).
  static const pinAnchor = Offset(_headX / _w, _tipY / _h);

  final Map<String, BitmapDescriptor> _cache = {};

  static String _key(SpeedPoint p) => '${p.type.key}_${p.speedLimit ?? 0}';

  /// Cached icon for the point, or a default pin until [prepare] finishes.
  BitmapDescriptor iconFor(SpeedPoint p) =>
      _cache[_key(p)] ??
      BitmapDescriptor.defaultMarkerWithHue(
        p.type == PointType.camera
            ? BitmapDescriptor.hueRed
            : BitmapDescriptor.hueOrange,
      );

  BitmapDescriptor? get car => _cache['car'];

  bool hasAll(Iterable<SpeedPoint> points) =>
      _cache.containsKey('car') &&
      points.every((p) => _cache.containsKey(_key(p)));

  /// Draws any icons not drawn yet. Returns true if something new was drawn.
  Future<bool> prepare(Iterable<SpeedPoint> points, double dpr) async {
    var changed = false;
    if (!_cache.containsKey('car')) {
      _cache['car'] = await _render(44, 44, dpr, _paintCar);
      changed = true;
    }
    for (final p in points) {
      final key = _key(p);
      if (_cache.containsKey(key)) continue;
      _cache[key] = await _render(
        _w,
        _h,
        dpr,
        (c, s) => _paintPin(c, p.type, p.speedLimit),
      );
      changed = true;
    }
    return changed;
  }

  static Future<BitmapDescriptor> _render(
    double w,
    double h,
    double dpr,
    void Function(Canvas canvas, Size size) paint,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(dpr);
    paint(canvas, Size(w, h));
    final image = await recorder.endRecording().toImage(
      (w * dpr).round(),
      (h * dpr).round(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(
      bytes!.buffer.asUint8List(),
      imagePixelRatio: dpr,
    );
  }

  static void _paintPin(Canvas c, PointType type, int? limit) {
    final color = colorFor(type);
    const outline = Color(0x33000000); // keeps the pin visible on white maps

    // Pointer + head as one shape.
    final shape = Path()
      ..addOval(Rect.fromCircle(center: _head, radius: _headR + 3))
      ..moveTo(_head.dx - 7, _head.dy + _headR)
      ..lineTo(_head.dx, _tipY)
      ..lineTo(_head.dx + 7, _head.dy + _headR)
      ..close();
    c.drawPath(
      shape,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    c.drawPath(shape, Paint()..color = Colors.white);
    c.drawCircle(_head, _headR, Paint()..color = color);

    final fg = type == PointType.camera
        ? Colors.white
        : const Color(0xFF1F1300);
    if (type == PointType.camera) {
      _drawIcon(c, Icons.photo_camera_rounded, _head, 19, fg);
    } else {
      c.drawPath(
        BumpPainter.pathFor(
          Rect.fromCenter(center: _head, width: 22, height: 22),
        ),
        Paint()
          ..color = fg
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    if (limit != null) {
      final center = _head + const Offset(17, -12);
      c.drawCircle(center, 11, Paint()..color = outline);
      c.drawCircle(center, 10.2, Paint()..color = Colors.white);
      c.drawCircle(
        center,
        8.6,
        Paint()
          ..color = const Color(0xFFDC2626)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '$limit',
          style: TextStyle(
            fontFamily: AppFonts.ui,
            color: const Color(0xFF111827),
            fontSize: limit >= 100 ? 7.5 : 9,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
    }
  }

  /// Blue navigation arrow with a white border (the map rotates it).
  static void _paintCar(Canvas c, Size s) {
    final m = s.width / 2;
    final arrow = Path()
      ..moveTo(m, 6)
      ..lineTo(m + 14, s.height - 7)
      ..lineTo(m, s.height - 13)
      ..lineTo(m - 14, s.height - 7)
      ..close();
    c.drawPath(
      arrow,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeJoin = StrokeJoin.round,
    );
    c.drawPath(arrow, Paint()..color = AppColors.primary);
  }

  static void _drawIcon(
    Canvas c,
    IconData icon,
    Offset center,
    double size,
    Color color,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }
}
