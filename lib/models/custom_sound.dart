/// A sound file the user picked from their phone (audio or video), copied
/// into the app so it keeps working even if the original is deleted.
class CustomSound {
  const CustomSound({required this.file, required this.name, this.durationMs});

  /// File name inside the app's sounds folder (not a full path: on iPhone
  /// the app folder moves after every update).
  final String file;

  /// The original file name, shown in the app.
  final String name;

  /// Length of the sound, if the phone could tell.
  final int? durationMs;

  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  static const _videoExtensions = {
    'mp4', 'mov', 'm4v', '3gp', '3g2', 'mkv', 'webm', 'avi', 'mpg', 'mpeg', //
    'ts', 'wmv', 'flv',
  };

  /// True if it came from a video (only its sound is played).
  bool get isVideo {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _videoExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  Map<String, dynamic> toJson() => {
    'file': file,
    'name': name,
    if (durationMs != null) 'ms': durationMs,
  };

  /// Returns null for missing or broken data instead of throwing.
  static CustomSound? fromJson(Object? json) {
    if (json is! Map) return null;
    final file = json['file'];
    if (file is! String || file.isEmpty) return null;
    final name = json['name'];
    return CustomSound(
      file: file,
      name: name is String && name.isNotEmpty ? name : file,
      durationMs: (json['ms'] as num?)?.round(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CustomSound &&
      other.file == file &&
      other.name == name &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(file, name, durationMs);
}

/// How many times a warning sound can be played in a row.
const int maxRepeat = 5;

/// Longer sounds are cut, so one long video can't block the next warning.
const Duration maxClipLength = Duration(seconds: 15);

/// "0:07", "1:23".
String formatClipLength(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
