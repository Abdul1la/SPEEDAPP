import 'custom_sound.dart';
import 'speed_point.dart';

enum MapLook {
  /// Light by day, dark by night (follows the phone's appearance).
  auto('Automatic'),
  dark('Dark'),
  light('Light'),
  standard('Google standard');

  const MapLook(this.label);
  final String label;
}

class AppSettings {
  const AppSettings({
    this.cameraDistances = const [500, 300, 200, 100],
    this.bumpDistances = const [300, 100],
    this.overSpeedTolerance = 5,
    this.muted = false,
    this.keepScreenOn = true,
    this.mapLook = MapLook.auto,
    this.sounds = const {},
    this.repeats = const {},
    this.sharePoints = true,
  });

  /// Distances in meters at which a warning is spoken, for each type.
  final List<int> cameraDistances;
  final List<int> bumpDistances;

  /// How many km/h over the limit before the "slow down" warning plays.
  final int overSpeedTolerance;

  final bool muted;
  final bool keepScreenOn;
  final MapLook mapLook;

  /// Sounds you picked, by slot name: "camera" (every camera distance),
  /// "camera_300" (one distance), "bump", "bump_100", "over_speed".
  /// See `SoundSlot`.
  final Map<String, CustomSound> sounds;

  /// How many times in a row each warning plays: "camera", "bump",
  /// "over_speed". Missing means once.
  final Map<String, int> repeats;

  /// New points are shared with other drivers (each point can still be
  /// made private in its editor).
  final bool sharePoints;

  int repeatFor(String group) => (repeats[group] ?? 1).clamp(1, maxRepeat);

  /// Sets (or with null, removes) your sound for one slot.
  AppSettings withSound(String slot, CustomSound? sound) {
    final next = {...sounds};
    if (sound == null) {
      next.remove(slot);
    } else {
      next[slot] = sound;
    }
    return copyWith(sounds: next);
  }

  AppSettings withRepeat(String group, int times) =>
      copyWith(repeats: {...repeats, group: times.clamp(1, maxRepeat)});

  /// Sorted from far to near, e.g. [500, 300, 200, 100].
  List<int> distancesFor(PointType type) {
    final list = switch (type) {
      PointType.camera => cameraDistances,
      PointType.bump => bumpDistances,
    };
    return [...list]..sort((a, b) => b.compareTo(a));
  }

  AppSettings copyWith({
    List<int>? cameraDistances,
    List<int>? bumpDistances,
    int? overSpeedTolerance,
    bool? muted,
    bool? keepScreenOn,
    MapLook? mapLook,
    Map<String, CustomSound>? sounds,
    Map<String, int>? repeats,
    bool? sharePoints,
  }) {
    return AppSettings(
      cameraDistances: cameraDistances ?? this.cameraDistances,
      bumpDistances: bumpDistances ?? this.bumpDistances,
      overSpeedTolerance: overSpeedTolerance ?? this.overSpeedTolerance,
      muted: muted ?? this.muted,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      mapLook: mapLook ?? this.mapLook,
      sounds: sounds ?? this.sounds,
      repeats: repeats ?? this.repeats,
      sharePoints: sharePoints ?? this.sharePoints,
    );
  }

  Map<String, dynamic> toJson() => {
    ...toBackupJson(),
    'sounds': {for (final e in sounds.entries) e.key: e.value.toJson()},
  };

  /// What is backed up to the account. Sound files stay on the phone, so
  /// their settings aren't included.
  Map<String, dynamic> toBackupJson() => {
    'cameraDistances': cameraDistances,
    'bumpDistances': bumpDistances,
    'overSpeedTolerance': overSpeedTolerance,
    'muted': muted,
    'keepScreenOn': keepScreenOn,
    'mapLook': mapLook.name,
    'repeats': repeats,
    'sharePoints': sharePoints,
  };

  /// Settings restored from a backup, keeping this phone's own sounds.
  AppSettings restoredFrom(Map<String, dynamic> backup) =>
      AppSettings.fromJson({...backup, 'sounds': toJson()['sounds']});

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const d = AppSettings();
    List<int> ints(Object? v, List<int> fallback) {
      if (v is! List) return fallback;
      final out = v.whereType<num>().map((n) => n.round()).where((n) => n > 0);
      return out.isEmpty ? fallback : out.toList();
    }

    final sounds = <String, CustomSound>{};
    if (json['sounds'] case final Map<dynamic, dynamic> m) {
      for (final e in m.entries) {
        final s = CustomSound.fromJson(e.value);
        if (e.key is String && s != null) sounds[e.key as String] = s;
      }
    }
    final repeats = <String, int>{};
    if (json['repeats'] case final Map<dynamic, dynamic> m) {
      for (final e in m.entries) {
        if (e.key is String && e.value is num) {
          repeats[e.key as String] = (e.value as num).round().clamp(
            1,
            maxRepeat,
          );
        }
      }
    }

    return AppSettings(
      sounds: sounds,
      repeats: repeats,
      cameraDistances: ints(json['cameraDistances'], d.cameraDistances),
      bumpDistances: ints(json['bumpDistances'], d.bumpDistances),
      overSpeedTolerance:
          (json['overSpeedTolerance'] as num?)?.round() ?? d.overSpeedTolerance,
      muted: json['muted'] as bool? ?? d.muted,
      keepScreenOn: json['keepScreenOn'] as bool? ?? d.keepScreenOn,
      sharePoints: json['sharePoints'] as bool? ?? d.sharePoints,
      mapLook: MapLook.values.firstWhere(
        (m) => m.name == json['mapLook'],
        orElse: () => d.mapLook,
      ),
    );
  }
}
