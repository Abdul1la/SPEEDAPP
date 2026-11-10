// Older widget names kept so existing code keeps compiling.
// They now draw the flat design from ui.dart. New code: use ui.dart.

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'ui.dart';

export 'ui.dart';

/// Older name for [IconTile] (soft tinted style).
class GlowIconBox extends StatelessWidget {
  const GlowIconBox({
    super.key,
    required this.color,
    this.icon,
    this.child,
    this.size = 36,
  });

  final Color color;
  final IconData? icon;
  final Widget? child;
  final double size;

  @override
  Widget build(BuildContext context) =>
      IconTile(color: color, icon: icon, size: size, soft: true, child: child);
}

/// Older name for [AppChip].
class NeonChip extends StatelessWidget {
  const NeonChip({
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
  Widget build(BuildContext context) => AppChip(
    label: label,
    selected: selected,
    onTap: onTap,
    color: color ?? context.palette.primary,
    icon: icon,
  );
}

/// Older name for [showAppSheet].
Future<T?> showNeonSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) => showAppSheet<T>(
  context: context,
  builder: builder,
  isScrollControlled: isScrollControlled,
);
