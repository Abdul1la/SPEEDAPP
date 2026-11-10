import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/speed_point.dart';
import '../services/alert_engine.dart';
import '../theme/app_theme.dart';
import 'ui.dart';

/// How sure the app is about a police radar, in a few words (one line on
/// the warning card): "Confirmed by 3 drivers · 5 min ago", "4 drivers
/// braked here · 12 min ago" (found automatically), "Reported 20 min ago ·
/// not confirmed yet".
String radarTrust(SpeedPoint point, [DateTime? now]) {
  final at = point.lastConfirmedAt ?? point.createdAt;
  final ago = at == null ? null : _ago((now ?? DateTime.now()).difference(at));
  String drivers(int n) => n == 1 ? '1 driver' : '$n drivers';
  if (point.confirms > 0) {
    return ['Confirmed by ${drivers(point.confirms)}', ?ago].join(' · ');
  }
  if (point.auto) {
    return [
      point.slowdowns > 0
          ? '${drivers(point.slowdowns)} braked here'
          : 'Found automatically',
      ?ago,
    ].join(' · ');
  }
  return [
    ago == null ? 'Reported' : 'Reported $ago',
    'not confirmed yet',
  ].join(' · ');
}

String _ago(Duration d) {
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  return '${d.inHours} h ago';
}

/// Warning pill at the top of the map while a camera / bump is ahead
/// (like an iPhone Live Activity).
///
/// Normal: frosted glass with a colored badge, the distance and the limit
/// sign. Over the limit: turns solid red so it can't be missed.
class WarningBanner extends StatelessWidget {
  const WarningBanner({super.key, required this.alert, required this.zone});

  final ActiveAlert alert;

  /// Farthest warning distance for this type (progress line is empty there).
  final int zone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final point = alert.point;
    final over = alert.overLimit;
    final accent = p.colorFor(point.type);
    final progress = (1 - alert.distance / zone).clamp(0.0, 1.0);
    final limit = point.speedLimit;
    final title = over ? 'Slow down' : point.type.label;

    return Semantics(
      liveRegion: true,
      label:
          '$title, ${formatDistance(alert.distance)} ahead'
          '${limit != null ? ', limit $limit' : ''}',
      child: ExcludeSemantics(
        child: Frosted(
          radius: 30,
          color: over ? p.danger : null,
          padding: const EdgeInsets.fromLTRB(12, 12, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  PointBadge(
                    color: over ? Colors.white.withValues(alpha: 0.22) : accent,
                    child: over
                        ? const Icon(
                            Icons.speed_rounded,
                            color: Colors.white,
                            size: 28,
                          )
                        : PointGlyph(
                            type: point.type,
                            size: 28,
                            color: p.onColorFor(point.type),
                          ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: over ? Colors.white : accent,
                          ),
                        ),
                        const SizedBox(height: 3),
                        AnimatedDistance(
                          meters: alert.distance,
                          color: over ? Colors.white : p.text,
                          fontSize: 34,
                        ),
                      ],
                    ),
                  ),
                  if (limit != null) ...[
                    const SizedBox(width: Space.sm),
                    LimitSign(limit: limit, size: 52),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              _ProgressLine(
                progress: progress,
                color: over ? Colors.white : accent,
                track: over ? Colors.white.withValues(alpha: 0.3) : p.fill,
              ),
              if (point.type.temporary) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      point.confirms > 0 || point.slowdowns >= 3
                          ? Icons.verified_rounded
                          : Icons.help_outline_rounded,
                      size: 15,
                      color: over ? Colors.white : p.textSecondary,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        radarTrust(point),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: over ? Colors.white : p.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// After driving past a police radar: "Still there?" with two big buttons.
/// The answers keep the map accurate (it hides itself after a few seconds).
class StillThereCard extends StatelessWidget {
  const StillThereCard({
    super.key,
    required this.point,
    required this.onAnswer,
    required this.onClose,
  });

  final SpeedPoint point;
  final ValueChanged<bool> onAnswer;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget answer(bool yes) => Expanded(
      child: SizedBox(
        height: 52,
        child: FilledButton.icon(
          onPressed: () => onAnswer(yes),
          style: FilledButton.styleFrom(
            backgroundColor: yes ? p.success : p.danger,
            foregroundColor: Colors.white,
          ),
          icon: Icon(yes ? Icons.check_rounded : Icons.close_rounded),
          // Bigger than usual, keeping the app's font from the theme.
          label: Text(
            yes ? 'Still there' : 'Not there',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );

    return Semantics(
      liveRegion: true,
      label: 'Police radar still there?',
      child: Frosted(
        radius: 30,
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                PointBadge(
                  size: 44,
                  color: p.colorFor(point.type),
                  child: PointGlyph(
                    type: point.type,
                    size: 24,
                    color: p.onColorFor(point.type),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Police radar still there?',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        radarTrust(point),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: p.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: onClose,
                  icon: Icon(Icons.close_rounded, color: p.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                children: [
                  answer(true),
                  const SizedBox(width: Space.sm),
                  answer(false),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({
    required this.progress,
    required this.color,
    required this.track,
  });

  final double progress;
  final Color color;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 4,
      decoration: BoxDecoration(
        color: track,
        borderRadius: BorderRadius.circular(2),
      ),
      alignment: Alignment.centerLeft,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: progress),
        duration: const Duration(milliseconds: 800),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => FractionallySizedBox(
          widthFactor: math.max(v, 0.02),
          child: Container(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

/// Distance that counts down smoothly ("290 m" / "1.2 km").
class AnimatedDistance extends StatelessWidget {
  const AnimatedDistance({
    super.key,
    required this.meters,
    required this.color,
    this.fontSize = 40,
  });

  final double meters;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: meters),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) {
        final parts = formatDistance(v).split(' ');
        return Text.rich(
          TextSpan(
            children: [
              TextSpan(text: parts.first),
              TextSpan(
                text: ' ${parts.last}',
                style: TextStyle(
                  fontSize: fontSize * 0.52,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                  color: color.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          maxLines: 1,
          style: numberStyle(fontSize, color: color, weight: FontWeight.w800),
        );
      },
    );
  }
}

/// Round speed limit sign (white with a red ring), like the real one.
class LimitSign extends StatelessWidget {
  const LimitSign({super.key, required this.limit, this.size = 56});

  final int limit;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFE5112F), width: size * 0.11),
      ),
      alignment: Alignment.center,
      child: Text(
        '$limit',
        style: numberStyle(
          size * (limit >= 100 ? 0.32 : 0.4),
          color: const Color(0xFF0B0B0F),
          weight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Round speedometer. A thin ring fills toward the speed limit:
/// blue when fine, orange within 5 km/h, red (and red dial) when over.
class SpeedGauge extends StatelessWidget {
  const SpeedGauge({
    super.key,
    required this.kmh,
    this.limit,
    this.overLimit = false,
    this.size = 92,
  });

  final double kmh;
  final int? limit;
  final bool overLimit;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final l = limit;
    final near = l != null && !overLimit && kmh >= l - 5;
    final ring = overLimit
        ? Colors.white
        : near
        ? p.warning
        : p.primary;
    final fg = overLimit ? Colors.white : p.text;

    return Semantics(
      label:
          'Speed ${kmh.round()} kilometers per hour'
          '${l != null ? ', limit $l' : ''}',
      child: ExcludeSemantics(
        child: Frosted(
          radius: size / 2,
          color: overLimit ? p.danger : null,
          child: SizedBox.square(
            dimension: size,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: kmh),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) {
                final max = l != null ? l * 1.25 : 140.0;
                return CustomPaint(
                  painter: _RingPainter(
                    progress: (v / max).clamp(0.0, 1.0),
                    color: ring,
                    track: overLimit
                        ? Colors.white.withValues(alpha: 0.3)
                        : p.fill,
                    limitAt: l != null ? 1 / 1.25 : null,
                  ),
                  // Scales down instead of overflowing with large text.
                  child: Padding(
                    padding: EdgeInsets.all(size * 0.2),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            v.round().toString(),
                            style: numberStyle(
                              size * 0.36,
                              color: fg,
                              weight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'km/h',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: overLimit
                                  ? Colors.white.withValues(alpha: 0.85)
                                  : p.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
    this.limitAt,
  });

  final double progress;
  final Color color;
  final Color track;

  /// Where the speed limit sits on the ring (0..1), shown as a small tick.
  final double? limitAt;

  static const _start = math.pi * 0.75;
  static const _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 4.0;
    final rect = (Offset.zero & size).deflate(7);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _start, _sweep, false, paint..color = track);
    if (progress > 0.005) {
      canvas.drawArc(
        rect,
        _start,
        _sweep * progress,
        false,
        paint..color = color,
      );
    }
    final at = limitAt;
    if (at != null) {
      final a = _start + _sweep * at;
      final c = rect.center;
      final r = rect.width / 2;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        c + d * (r - 5),
        c + d * (r + 5),
        Paint()
          ..color = const Color(0xFFE5112F)
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.track != track ||
      old.limitAt != limitAt;
}

/// Small frosted capsule with a colored dot, e.g. "Finding GPS…".
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.color,
    required this.label,
    this.trailing,
    this.onTap,
  });

  final Color color;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Frosted(
      radius: 20,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: SizedBox(
            height: 40,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: Space.sm),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: Space.sm),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
