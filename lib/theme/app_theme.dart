import 'package:flutter/material.dart';

import '../models/speed_point.dart';

/// Design system for Speed Alert.
///
/// Modern iOS-style look: a full-screen map with floating frosted-glass
/// capsules (no drop shadows), Apple system colors, grouped sheets
/// (white cards on a grey background), big glanceable numbers. Color is
/// used only for meaning: red = camera / danger, orange = speed bump,
/// blue = something you can tap.
///
/// Read colors with `context.palette` so they follow light / dark mode.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.glass,
    required this.glassBorder,
    required this.fill,
    required this.thumb,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.primary,
    required this.onPrimary,
    required this.primarySoft,
    required this.camera,
    required this.cameraSoft,
    required this.bump,
    required this.onBump,
    required this.bumpSoft,
    required this.danger,
    required this.success,
    required this.warning,
    this.radar = const Color(0xFF5856D6),
    this.radarSoft = const Color(0xFFECEBFB),
  });

  /// Police radar (mobile speed cameras): indigo, apart from cameras (red),
  /// bumps (orange) and buttons (blue).
  final Color radar;
  final Color radarSoft;

  /// Grouped background (behind cards, sheets).
  final Color bg;

  /// Cards and rows.
  final Color surface;

  /// Slightly raised fill inside cards.
  final Color surfaceAlt;
  final Color border;

  /// Frosted glass for controls floating over the map.
  final Color glass;
  final Color glassBorder;

  /// Translucent fill for chips and segmented-control tracks.
  final Color fill;

  /// Selected segment in a segmented control.
  final Color thumb;

  final Color text;
  final Color textSecondary;
  final Color textTertiary;

  final Color primary;
  final Color onPrimary;
  final Color primarySoft;

  final Color camera;
  final Color cameraSoft;
  final Color bump;
  final Color onBump;
  final Color bumpSoft;

  final Color danger;
  final Color success;
  final Color warning;

  static const light = Palette(
    bg: Color(0xFFF2F2F7),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF2F2F7),
    border: Color(0xFFE5E5EA),
    glass: Color(0xD6FFFFFF),
    glassBorder: Color(0x1A000000),
    fill: Color(0x1F767680),
    thumb: Color(0xFFFFFFFF),
    text: Color(0xFF0B0B0F),
    textSecondary: Color(0xFF6B6B73),
    textTertiary: Color(0xFFA1A1AA),
    primary: Color(0xFF007AFF),
    onPrimary: Color(0xFFFFFFFF),
    primarySoft: Color(0xFFE5F0FF),
    camera: Color(0xFFFF3B30),
    cameraSoft: Color(0xFFFFE9E7),
    bump: Color(0xFFFF9500),
    onBump: Color(0xFFFFFFFF),
    bumpSoft: Color(0xFFFFF1DE),
    danger: Color(0xFFFF3B30),
    success: Color(0xFF34C759),
    warning: Color(0xFFFF9500),
  );

  static const dark = Palette(
    bg: Color(0xFF000000),
    surface: Color(0xFF1C1C1E),
    surfaceAlt: Color(0xFF2C2C2E),
    border: Color(0xFF38383A),
    glass: Color(0xCC1C1C1E),
    glassBorder: Color(0x26FFFFFF),
    fill: Color(0x3D767680),
    thumb: Color(0xFF636366),
    text: Color(0xFFFFFFFF),
    textSecondary: Color(0xFF98989F),
    textTertiary: Color(0xFF636366),
    primary: Color(0xFF0A84FF),
    onPrimary: Color(0xFFFFFFFF),
    primarySoft: Color(0xFF0B2A4D),
    camera: Color(0xFFFF453A),
    cameraSoft: Color(0xFF3B1513),
    bump: Color(0xFFFF9F0A),
    onBump: Color(0xFFFFFFFF),
    bumpSoft: Color(0xFF3A2508),
    danger: Color(0xFFFF453A),
    success: Color(0xFF30D158),
    warning: Color(0xFFFF9F0A),
    radar: Color(0xFF7D7AFF),
    radarSoft: Color(0xFF1E1D45),
  );

  Color colorFor(PointType t) => switch (t) {
    PointType.camera => camera,
    PointType.bump => bump,
    PointType.mobile => radar,
  };
  Color onColorFor(PointType t) => switch (t) {
    PointType.camera || PointType.mobile => Colors.white,
    PointType.bump => onBump,
  };
  Color softFor(PointType t) => switch (t) {
    PointType.camera => cameraSoft,
    PointType.bump => bumpSoft,
    PointType.mobile => radarSoft,
  };

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return Palette(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surfaceAlt: l(surfaceAlt, other.surfaceAlt),
      border: l(border, other.border),
      glass: l(glass, other.glass),
      glassBorder: l(glassBorder, other.glassBorder),
      fill: l(fill, other.fill),
      thumb: l(thumb, other.thumb),
      text: l(text, other.text),
      textSecondary: l(textSecondary, other.textSecondary),
      textTertiary: l(textTertiary, other.textTertiary),
      primary: l(primary, other.primary),
      onPrimary: l(onPrimary, other.onPrimary),
      primarySoft: l(primarySoft, other.primarySoft),
      camera: l(camera, other.camera),
      cameraSoft: l(cameraSoft, other.cameraSoft),
      bump: l(bump, other.bump),
      onBump: l(onBump, other.onBump),
      bumpSoft: l(bumpSoft, other.bumpSoft),
      danger: l(danger, other.danger),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      radar: l(radar, other.radar),
      radarSoft: l(radarSoft, other.radarSoft),
    );
  }
}

extension PaletteContext on BuildContext {
  Palette get palette => Theme.of(this).extension<Palette>() ?? Palette.light;
}

/// Spacing (4-pt grid) and corner radii, used everywhere for consistency.
abstract final class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
}

abstract final class Radii {
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 22.0;
  static const xl = 32.0;
}

abstract final class AppFonts {
  static const ui = 'Inter';
}

/// Fixed colors that don't change with the theme (map pins, older code).
/// New UI code should prefer `context.palette`.
abstract final class AppColors {
  static const primary = Color(0xFF007AFF);
  static const camera = Color(0xFFFF3B30);
  static const bump = Color(0xFFFF9500);
  static const radar = Color(0xFF5856D6);
  static const danger = Color(0xFFFF3B30);
  static const success = Color(0xFF34C759);
  static const textMuted = Color(0xFF8A93A3);
  static const textFaint = Color(0xFFA3ABB8);

  // Older names, kept so existing code compiles.
  static const cyan = primary;
  static const violet = primary;
  static const surfaceHigh = Color(0x14808080);
  static const outline = Color(0x33808080);
}

Color colorFor(PointType t) => switch (t) {
  PointType.camera => AppColors.camera,
  PointType.bump => AppColors.bump,
  PointType.mobile => AppColors.radar,
};

// ---- Older names, kept so existing code compiles (flat now). ------------

/// Older shadow helper: the design is flat, so these are empty.
abstract final class AppShadows {
  static List<BoxShadow> glow(Color c, {double strength = 1}) => const [];
  static List<BoxShadow> panel([Color? glow]) => const [];
  static List<Shadow> text(Color c, {double blur = 0}) => const [];
}

/// Older label style: small semibold caption.
TextStyle hudLabel(Color color, {double size = 12}) => TextStyle(
  fontFamily: AppFonts.ui,
  color: color,
  fontSize: size,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.2,
);

/// Older gradient name: now a solid primary fill.
const primaryGradient = LinearGradient(
  colors: [AppColors.primary, AppColors.primary],
);

/// Big tabular number (speed, distance) that doesn't jiggle as it changes.
TextStyle numberStyle(
  double size, {
  Color? color,
  FontWeight weight = FontWeight.w700,
}) => TextStyle(
  fontFamily: AppFonts.ui,
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: 1.0,
  letterSpacing: -size * 0.035,
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// "1.2 km" or "290 m" (rounded to 10 m).
String formatDistance(double meters) {
  if (meters >= 1000) {
    final km = meters / 1000;
    return '${km >= 10 ? km.round() : km.toStringAsFixed(1)} km';
  }
  return '${(meters / 10).round() * 10} m';
}

ThemeData buildAppTheme([Brightness brightness = Brightness.light]) {
  final p = brightness == Brightness.dark ? Palette.dark : Palette.light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.primary,
        brightness: brightness,
      ).copyWith(
        primary: p.primary,
        onPrimary: p.onPrimary,
        primaryContainer: p.primarySoft,
        onPrimaryContainer: p.primary,
        secondaryContainer: p.primarySoft,
        onSecondaryContainer: p.primary,
        surface: p.surface,
        onSurface: p.text,
        onSurfaceVariant: p.textSecondary,
        surfaceContainerLowest: p.surface,
        surfaceContainerLow: p.surface,
        surfaceContainer: p.surfaceAlt,
        surfaceContainerHigh: p.surfaceAlt,
        surfaceContainerHighest: p.surfaceAlt,
        outline: p.border,
        outlineVariant: p.border,
        error: p.danger,
        shadow: Colors.transparent,
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: AppFonts.ui,
    extensions: [p],
  );
  final r14 = BorderRadius.circular(Radii.md);
  final t = base.textTheme.apply(bodyColor: p.text, displayColor: p.text);

  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    // Flat design: no shadows anywhere.
    shadowColor: Colors.transparent,
    splashFactory: InkRipple.splashFactory,
    textTheme: t.copyWith(
      displaySmall: t.displaySmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -1,
      ),
      headlineMedium: t.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
      ),
      headlineSmall: t.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      ),
      titleLarge: t.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
      titleMedium: t.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      bodyLarge: t.bodyLarge?.copyWith(letterSpacing: -0.1),
      bodyMedium: t.bodyMedium?.copyWith(
        color: p.textSecondary,
        letterSpacing: -0.1,
      ),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      modalBarrierColor: Colors.black.withValues(alpha: 0.4),
      showDragHandle: true,
      dragHandleColor: p.textTertiary.withValues(alpha: 0.5),
      dragHandleSize: const Size(36, 5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: brightness == Brightness.dark
          ? const Color(0xFFF4F5F7)
          : const Color(0xFF111827),
      contentTextStyle: TextStyle(
        fontFamily: AppFonts.ui,
        color: brightness == Brightness.dark
            ? const Color(0xFF111827)
            : Colors.white,
        fontWeight: FontWeight.w500,
        fontSize: 15,
      ),
      actionTextColor: brightness == Brightness.dark
          ? Palette.light.primary
          : const Color(0xFF93B4FF),
      shape: RoundedRectangleBorder(borderRadius: r14),
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.xl),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: Space.xl),
        shape: const StadiumBorder(),
        elevation: 0,
        textStyle: const TextStyle(
          fontFamily: AppFonts.ui,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: Space.lg),
        foregroundColor: p.primary,
        backgroundColor: p.primarySoft,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(
          fontFamily: AppFonts.ui,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.primary,
        shape: RoundedRectangleBorder(borderRadius: r14),
        textStyle: const TextStyle(
          fontFamily: AppFonts.ui,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: p.text),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.success : p.fill,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.selected) ? p.success : Colors.transparent,
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: p.primary,
      inactiveTrackColor: p.fill,
      thumbColor: Colors.white,
      overlayColor: p.primary.withValues(alpha: 0.12),
      showValueIndicator: ShowValueIndicator.never,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      hintStyle: TextStyle(color: p.textTertiary),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: 15,
      ),
      border: OutlineInputBorder(
        borderRadius: r14,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: r14,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: r14,
        borderSide: BorderSide(color: p.primary, width: 1.5),
      ),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(iconColor: p.textSecondary),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: brightness == Brightness.dark
            ? const Color(0xFFF4F5F7)
            : const Color(0xFF111827),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(
        fontFamily: AppFonts.ui,
        color: brightness == Brightness.dark
            ? const Color(0xFF111827)
            : Colors.white,
      ),
    ),
  );
}
