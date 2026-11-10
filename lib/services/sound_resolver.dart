import '../models/custom_sound.dart';
import '../models/speed_point.dart';
import '../models/warning_tone.dart';

/// Names of the warning sounds. They match the built-in recordings in
/// `assets/sounds/` (e.g. `camera_300.mp3`) and the keys of your own sounds
/// saved in settings.
abstract final class SoundSlot {
  /// Every warning distance of this type ("camera", "bump").
  static String type(PointType t) => t.key;

  /// One warning distance ("camera_300").
  static String distance(PointType t, int meters) => '${t.key}_$meters';

  /// The "slow down" warning.
  static const overSpeed = 'over_speed';

  /// Slots to try for an approach warning, most specific first.
  static List<String> forApproach(PointType t, int meters) => [
    distance(t, meters),
    type(t),
  ];

  /// The warning type of a slot ("camera_300" -> camera), or null for
  /// [overSpeed].
  static PointType? typeOf(String slot) {
    for (final t in PointType.values) {
      if (slot == t.key || slot.startsWith('${t.key}_')) return t;
    }
    return null;
  }
}

/// Where a warning's sound comes from.
enum SoundOrigin {
  /// The point's own sound (set on that one point).
  point,

  /// A sound you picked in Settings.
  custom,

  /// A recording shipped inside the app (`assets/sounds/`).
  builtIn,

  /// The built-in warning sound chosen in Settings (Chime, Alert...).
  tone,

  /// The phone's text-to-speech voice.
  phoneVoice,
}

class ResolvedSound {
  const ResolvedSound(this.origin, {this.custom, this.asset, this.tone});

  final SoundOrigin origin;

  /// For [SoundOrigin.point] and [SoundOrigin.custom].
  final CustomSound? custom;

  /// For [SoundOrigin.builtIn] and [SoundOrigin.tone]: the asset path,
  /// e.g. `assets/sounds/camera.mp3`.
  final String? asset;

  /// For [SoundOrigin.tone].
  final WarningTone? tone;
}

/// Picks the sound for a warning, most specific first:
///  1. the point's own sound ([own]),
///  2. your sound for each slot in [slots] (e.g. camera_300, then camera),
///  3. a built-in recording for each slot,
///  4. the built-in sound chosen in Settings ([tone]),
///  5. the phone voice.
/// Your sounds come before the built-in ones, so a sound you pick for
/// "all speed cameras" is used even where the app has a recording for one
/// distance. Missing files are skipped.
ResolvedSound resolveSound({
  required List<String> slots,
  CustomSound? own,
  required Map<String, CustomSound> userSounds,
  required bool Function(CustomSound sound) fileExists,
  required String? Function(String slot) assetFor,
  WarningTone? tone,
}) {
  if (own != null && fileExists(own)) {
    return ResolvedSound(SoundOrigin.point, custom: own);
  }
  for (final slot in slots) {
    final s = userSounds[slot];
    if (s != null && fileExists(s)) {
      return ResolvedSound(SoundOrigin.custom, custom: s);
    }
  }
  for (final slot in slots) {
    final a = assetFor(slot);
    if (a != null) return ResolvedSound(SoundOrigin.builtIn, asset: a);
  }
  if (tone != null) {
    return ResolvedSound(SoundOrigin.tone, asset: tone.asset, tone: tone);
  }
  return const ResolvedSound(SoundOrigin.phoneVoice);
}
