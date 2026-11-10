import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/speed_point.dart';
import '../theme/app_theme.dart';
import '../widgets/ui.dart';

/// Draws our own map pins (camera / speed bump / the driver's car) in code, so there
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
      BitmapDescriptor.defaultMarkerWithHue(switch (p.type) {
        PointType.camera => BitmapDescriptor.hueRed,
        PointType.bump => BitmapDescriptor.hueOrange,
        PointType.mobile => BitmapDescriptor.hueViolet,
      });

  BitmapDescriptor? get car => _cache['car'];

  bool hasAll(Iterable<SpeedPoint> points) =>
      _cache.containsKey('car') &&
      points.every((p) => _cache.containsKey(_key(p)));

  /// Draws any icons not drawn yet. Returns true if something new was drawn.
  Future<bool> prepare(Iterable<SpeedPoint> points, double dpr) async {
    var changed = false;
    if (!_cache.containsKey('car')) {
      _cache['car'] = await _render(
        carSize.width,
        carSize.height,
        dpr,
        _paintCar,
      );
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

    final fg = type == PointType.bump ? const Color(0xFF1F1300) : Colors.white;
    if (type == PointType.camera) {
      _drawIcon(c, Icons.photo_camera_rounded, _head, 19, fg);
    } else if (type == PointType.mobile) {
      _drawIcon(c, Icons.local_police_rounded, _head, 19, fg);
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

  /// Size of the car icon (pointing up = driving direction).
  static const carSize = Size(46, 84);

  /// The driver's car: a modern electric car seen from above, shaded so it
  /// looks 3D (lies flat on the map, so it tilts with the map while driving).
  static void _paintCar(Canvas c, Size s) {
    final cx = s.width / 2;
    const bodyW = 30.0;
    const bodyH = 66.0;
    final top = (s.height - bodyH) / 2;
    final left = cx - bodyW / 2;
    final right = cx + bodyW / 2;
    final bottom = top + bodyH;

    // Soft shadow under the car.
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left - 2, top + 4, bodyW + 4, bodyH),
        const Radius.circular(14),
      ),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // Wheels, just showing at the sides.
    final tyre = Paint()..color = const Color(0xFF111827);
    for (final y in [top + 13, bottom - 21]) {
      for (final x in [left - 2.2, right - 2.8]) {
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, 5, 11),
            const Radius.circular(2),
          ),
          tyre,
        );
      }
    }

    // Body: rounded nose and tail, slightly narrower at the front.
    final body = Path()
      ..moveTo(cx, top)
      ..cubicTo(right - 2, top, right, top + 6, right, top + 16)
      ..lineTo(right, bottom - 12)
      ..cubicTo(right, bottom - 3, right - 4, bottom, cx, bottom)
      ..cubicTo(left + 4, bottom, left, bottom - 3, left, bottom - 12)
      ..lineTo(left, top + 16)
      ..cubicTo(left, top + 6, left + 2, top, cx, top)
      ..close();
    final bodyRect = Rect.fromLTRB(left, top, right, bottom);
    // Pearl white: lighter in the middle, darker at the curved sides.
    c.drawPath(
      body,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFFB8C2CF),
            Color(0xFFF8FAFC),
            Color(0xFFFFFFFF),
            Color(0xFFF1F4F8),
            Color(0xFFAEB8C6),
          ],
          stops: [0, 0.22, 0.5, 0.78, 1],
        ).createShader(bodyRect),
    );
    // Light from the front, shade toward the back.
    c.drawPath(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00FFFFFF), Color(0x00000000), Color(0x22000000)],
          stops: [0, 0.6, 1],
        ).createShader(bodyRect),
    );
    c.drawPath(
      body,
      Paint()
        ..color = const Color(0x8C1F2937)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // Side mirrors.
    final mirror = Paint()..color = const Color(0xFF1F2937);
    c.drawOval(
      Rect.fromCenter(
        center: Offset(left - 1.5, top + 24),
        width: 5,
        height: 3.4,
      ),
      mirror,
    );
    c.drawOval(
      Rect.fromCenter(
        center: Offset(right + 1.5, top + 24),
        width: 5,
        height: 3.4,
      ),
      mirror,
    );

    // Glass: windshield, panoramic roof, rear window (dark, with a sky reflection).
    const glass = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF3B4A63), Color(0xFF111827), Color(0xFF0B1220)],
    );
    final cabin = Path()
      ..moveTo(left + 4.5, top + 23)
      ..cubicTo(left + 7, top + 17, right - 7, top + 17, right - 4.5, top + 23)
      ..lineTo(right - 3.5, bottom - 20)
      ..cubicTo(
        right - 6,
        bottom - 15,
        left + 6,
        bottom - 15,
        left + 3.5,
        bottom - 20,
      )
      ..close();
    c.drawPath(cabin, Paint()..shader = glass.createShader(cabin.getBounds()));
    // Glass edge catching the light.
    c.drawPath(
      cabin,
      Paint()
        ..color = const Color(0x40FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
    // Thin curved roof pillars: windshield / panoramic roof / rear window.
    final pillar = Paint()
      ..color = const Color(0xCCCBD5E1)
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke;
    c.drawPath(
      Path()
        ..moveTo(left + 4.6, top + 32)
        ..quadraticBezierTo(cx, top + 29.5, right - 4.6, top + 32),
      pillar,
    );
    c.drawPath(
      Path()
        ..moveTo(left + 4, bottom - 25)
        ..quadraticBezierTo(cx, bottom - 23, right - 4, bottom - 25),
      pillar,
    );
    // Reflection streaks on the windshield and roof.
    final shine = Paint()
      ..color = const Color(0x4DFFFFFF)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    c.drawLine(
      Offset(left + 9, top + 22.5),
      Offset(left + 12.5, top + 28.5),
      shine,
    );
    c.drawLine(
      Offset(right - 10, top + 36),
      Offset(right - 7, top + 48),
      shine..strokeWidth = 1.2,
    );

    // Hood lines and the edge of the front trunk.
    final crease = Paint()
      ..color = const Color(0x3D334155)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    c.drawLine(Offset(cx - 5, top + 6), Offset(cx - 6.5, top + 16), crease);
    c.drawLine(Offset(cx + 5, top + 6), Offset(cx + 6.5, top + 16), crease);
    c.drawPath(
      Path()
        ..moveTo(left + 3, top + 17.5)
        ..quadraticBezierTo(cx, top + 15, right - 3, top + 17.5),
      crease,
    );
    // Door seams along the sides.
    for (final y in [top + 38.0, bottom - 30.0]) {
      c.drawLine(Offset(left + 0.8, y), Offset(left + 3, y), crease);
      c.drawLine(Offset(right - 3, y), Offset(right - 0.8, y), crease);
    }

    // LED headlights (thin light strips at the front corners).
    final led = Paint()
      ..color = const Color(0xFFE0F7FF)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 1.5);
    c.drawLine(Offset(left + 3, top + 8), Offset(left + 9, top + 3.2), led);
    c.drawLine(Offset(right - 3, top + 8), Offset(right - 9, top + 3.2), led);

    // Full-width rear light bar.
    c.drawLine(
      Offset(left + 4, bottom - 3),
      Offset(right - 4, bottom - 3),
      Paint()
        ..color = const Color(0xFFFF2D46)
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 1.5),
    );
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
