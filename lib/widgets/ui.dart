import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models/speed_point.dart';
import '../theme/app_theme.dart';

/// Frosted glass surface for anything floating over the map (iOS style):
/// blurred, translucent, hairline edge, no drop shadow.
class Frosted extends StatelessWidget {
  const Frosted({
    super.key,
    required this.child,
    this.radius = Radii.lg,
    this.padding = EdgeInsets.zero,
    this.color,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// Override the glass tint (e.g. solid red for an urgent warning).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final r = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            color: color ?? p.glass,
            borderRadius: r,
            border: Border.all(color: p.glassBorder, width: 0.6),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Flat card: solid surface, no shadow. Used in sheets and settings.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = Radii.lg,
    this.color,
    this.borderColor,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: borderColor == null
          ? BorderSide.none
          : BorderSide(color: borderColor!),
    );
    return Material(
      color: color ?? p.surface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// One button in a [MapControlGroup].
class MapControl {
  const MapControl({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.activeColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;
}

/// Vertical frosted capsule of map buttons (like Apple Maps).
class MapControlGroup extends StatelessWidget {
  const MapControlGroup({super.key, required this.controls});
  final List<MapControl> controls;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Frosted(
      radius: 26,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < controls.length; i++) ...[
            if (i > 0) Container(width: 24, height: 0.6, color: p.glassBorder),
            _ControlButton(control: controls[i]),
          ],
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({required this.control});
  final MapControl control;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c = control;
    return Tooltip(
      message: c.tooltip,
      child: Semantics(
        button: true,
        label: c.tooltip,
        child: InkWell(
          onTap: c.onTap,
          child: SizedBox(
            width: 52,
            height: 50,
            child: Icon(
              c.icon,
              size: 22,
              color: c.active ? (c.activeColor ?? p.primary) : p.text,
            ),
          ),
        ),
      ),
    );
  }
}

/// Round frosted button for the map.
class GlassCircleButton extends StatelessWidget {
  const GlassCircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 52,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Frosted(
        radius: size / 2,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: size,
            child: Icon(icon, size: 22, color: context.palette.text),
          ),
        ),
      ),
    );
  }
}

/// iOS-style icon square with a soft top-to-bottom gradient.
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.color,
    this.icon,
    this.child,
    this.size = 30,
    this.soft = false,
    this.foreground,
  });

  final Color color;
  final IconData? icon;
  final Widget? child;
  final double size;

  /// Light tinted background with colored icon instead of solid.
  final bool soft;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final fg = foreground ?? (soft ? color : Colors.white);
    final top = Color.lerp(color, Colors.white, 0.18)!;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: soft ? color.withValues(alpha: 0.14) : null,
        gradient: soft
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [top, color],
              ),
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      alignment: Alignment.center,
      child: IconTheme.merge(
        data: IconThemeData(color: fg, size: size * 0.58),
        child: child ?? Icon(icon),
      ),
    );
  }
}

/// Icon tile for a point type (red camera / orange bump).
class PointTile extends StatelessWidget {
  const PointTile({super.key, required this.type, this.size = 30});
  final PointType type;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconTile(
      color: p.colorFor(type),
      size: size,
      child: PointGlyph(
        type: type,
        size: size * 0.58,
        color: p.onColorFor(type),
      ),
    );
  }
}

/// Round badge with a gradient fill (used for the warning icon).
class PointBadge extends StatelessWidget {
  const PointBadge({
    super.key,
    required this.color,
    required this.child,
    this.size = 52,
  });

  final Color color;
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(color, Colors.white, 0.2)!, color],
        ),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}

/// Pill-shaped selectable chip.
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c = color ?? p.primary;
    final fg = selected ? Colors.white : p.text;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 38),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? c : p.fill,
            borderRadius: BorderRadius.circular(19),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Segment<T> {
  const Segment(this.value, this.label, {this.icon});
  final T value;
  final String label;
  final Widget? icon;
}

/// iOS-style segmented control with a sliding thumb.
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  final List<Segment<T>> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final index = segments.indexWhere((s) => s.value == value);
    final n = segments.length;
    return Container(
      height: 40,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.fill,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Stack(
        children: [
          if (index >= 0)
            AnimatedAlign(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              alignment: Alignment(n == 1 ? 0 : -1 + 2 * index / (n - 1), 0),
              child: FractionallySizedBox(
                widthFactor: 1 / n,
                heightFactor: 1,
                child: Container(
                  decoration: BoxDecoration(
                    color: p.thumb,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: p.glassBorder, width: 0.5),
                  ),
                ),
              ),
            ),
          Row(
            children: [
              for (final s in segments)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: s.value == value,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onChanged(s.value),
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (s.icon != null) ...[
                              s.icon!,
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(
                                s.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: s.value == value
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: p.text,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small section title above a group ("Speed limit").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.padding});
  final String text;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding:
        padding ??
        const EdgeInsets.only(left: 4, top: Space.xxl, bottom: Space.sm),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: context.palette.textSecondary,
      ),
    ),
  );
}

/// Title row at the top of a sheet, with an optional close button.
class SheetHeader extends StatelessWidget {
  const SheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onClose,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.6,
                  color: p.text,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: TextStyle(fontSize: 14, color: p.textSecondary),
                ),
              ],
            ],
          ),
        ),
        if (onClose != null)
          IconButton(
            onPressed: onClose,
            tooltip: 'Close',
            style: IconButton.styleFrom(
              backgroundColor: p.fill,
              minimumSize: const Size(32, 32),
              fixedSize: const Size(32, 32),
              padding: EdgeInsets.zero,
            ),
            icon: Icon(Icons.close_rounded, size: 18, color: p.textSecondary),
          ),
      ],
    );
  }
}

/// Standard bottom sheet: grouped background, rounded top, grabber.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: true,
    builder: (context) => SafeArea(top: false, child: builder(context)),
  );
}

/// Camera / speed bump symbol, used everywhere so they always look the same.
class PointGlyph extends StatelessWidget {
  const PointGlyph({super.key, required this.type, this.size = 24, this.color});

  final PointType type;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? Colors.white;
    if (type == PointType.camera) {
      return Icon(Icons.photo_camera_rounded, size: size, color: c);
    }
    return CustomPaint(size: Size.square(size), painter: BumpPainter(c));
  }
}

/// A road with a hump: the speed bump symbol.
class BumpPainter extends CustomPainter {
  const BumpPainter(this.color);
  final Color color;

  static Path pathFor(Rect r) {
    final w = r.width;
    final h = r.height;
    final base = r.top + h * 0.72;
    return Path()
      ..moveTo(r.left + w * 0.06, base)
      ..lineTo(r.left + w * 0.24, base)
      ..cubicTo(
        r.left + w * 0.34,
        base,
        r.left + w * 0.36,
        r.top + h * 0.26,
        r.left + w * 0.5,
        r.top + h * 0.26,
      )
      ..cubicTo(
        r.left + w * 0.64,
        r.top + h * 0.26,
        r.left + w * 0.66,
        base,
        r.left + w * 0.76,
        base,
      )
      ..lineTo(r.left + w * 0.94, base);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      pathFor(Offset.zero & size),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.12
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(BumpPainter old) => old.color != color;
}
