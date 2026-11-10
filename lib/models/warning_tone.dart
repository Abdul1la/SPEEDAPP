import 'speed_point.dart';

/// Warning sounds that come with the app, in `assets/sounds/tones/`
/// (original sounds made for Speed Alert).
enum WarningTone {
  chime('chime', 'Chime', 'Two rising bells'),
  alert('alert', 'Alert', 'Three sharp beeps'),
  radar('radar', 'Radar', 'Five quick pips'),
  ding('ding', 'Ding', 'One soft bell'),
  bump('bump', 'Bump-bump', 'Two low knocks'),
  doubleBeep('double_beep', 'Double beep', 'Two gentle beeps');

  const WarningTone(this.key, this.label, this.description);

  /// Stable id, used in saved settings and as the file name.
  final String key;
  final String label;
  final String description;

  /// e.g. `assets/sounds/tones/chime.wav`.
  String get asset => 'assets/sounds/tones/$key.wav';

  /// What each warning plays until you choose something else.
  static WarningTone defaultFor(PointType type) => switch (type) {
    PointType.camera => chime,
    PointType.bump => bump,
    PointType.mobile => alert,
  };

  static WarningTone? fromKey(String? key) {
    for (final t in values) {
      if (t.key == key) return t;
    }
    return null;
  }
}

/// Saved in settings instead of a tone key: use the phone's voice only.
const String phoneVoiceTone = 'voice';
