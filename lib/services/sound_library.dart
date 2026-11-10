import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/custom_sound.dart';

/// Where to pick a sound from.
enum SoundPickSource {
  /// The phone's file browser: any file (audio, video, anything).
  files,

  /// The photo gallery: videos only (their sound is used).
  videos,
}

/// A problem picking a sound, with a message that can be shown to the user.
class SoundImportException implements Exception {
  const SoundImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Keeps the sound files the user picked, in the app's own folder.
class SoundLibrary {
  /// Bigger files are refused (a long video wastes space for a short sound).
  static const int maxBytes = 100 * 1024 * 1024;

  Directory? _dir;
  final Set<String> _files = {};
  int _counter = 0;

  Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}sounds');
      await dir.create(recursive: true);
      _dir = dir;
      _files
        ..clear()
        ..addAll(
          dir.listSync().whereType<File>().map((f) => _baseName(f.path)),
        );
    } catch (e) {
      debugPrint('Sound folder not available: $e');
    }
  }

  /// Full path of the file, or null if it is missing (for example a point
  /// imported from another phone).
  String? pathOf(CustomSound? sound) {
    final dir = _dir;
    if (sound == null || dir == null || !_files.contains(sound.file)) {
      return null;
    }
    return '${dir.path}${Platform.pathSeparator}${sound.file}';
  }

  bool has(CustomSound? sound) => pathOf(sound) != null;

  /// Opens the phone's picker and copies the chosen file into the app.
  /// Returns null if the user cancelled. Throws [SoundImportException] if
  /// the file can't be used. [onCopying] is called once a file was chosen,
  /// before the (possibly slow) copy and check.
  Future<CustomSound?> pick(
    SoundPickSource source, {
    VoidCallback? onCopying,
  }) async {
    final dir = _dir;
    if (dir == null) {
      throw const SoundImportException('The app storage is not available.');
    }

    final PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        type: source == SoundPickSource.videos ? FileType.video : FileType.any,
      );
    } catch (e) {
      debugPrint('File picker failed: $e');
      throw const SoundImportException('Could not open the file picker.');
    }
    if (picked == null) return null;
    onCopying?.call();

    try {
      final size = picked.lengthSync() ?? await picked.length();
      if (size == 0) {
        throw const SoundImportException('This file is empty.');
      }
      if (size != null && size > maxBytes) {
        throw SoundImportException(
          'This file is too big (${size ~/ (1024 * 1024)} MB). '
          'Pick one under ${maxBytes ~/ (1024 * 1024)} MB.',
        );
      }

      // Keep the extension: iPhone uses it to know how to play the file.
      final ext = (picked.extension ?? '').toLowerCase();
      final safeExt = RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext) ? '.$ext' : '';
      final stored =
          'sound_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
          '${(_counter++).toRadixString(36)}$safeExt';
      final out = File('${dir.path}${Platform.pathSeparator}$stored');

      try {
        final sink = out.openWrite();
        try {
          await sink.addStream(picked.readAsByteStream());
        } finally {
          await sink.close();
        }
      } catch (e) {
        debugPrint('Copying the sound failed: $e');
        await _delete(out);
        throw const SoundImportException('Could not copy the file.');
      }

      final Duration? length;
      try {
        length = await probe(out.path);
      } catch (e) {
        debugPrint('Sound check failed: $e');
        await _delete(out);
        throw SoundImportException(
          'The phone can\'t play the sound in "${picked.name}". '
          'Try an MP3, M4A or WAV file, or a normal MP4 / MOV video.',
        );
      }

      _files.add(stored);
      return CustomSound(
        file: stored,
        name: picked.name,
        durationMs: length?.inMilliseconds,
      );
    } finally {
      // The picker may have made its own temporary copy.
      unawaited(FilePicker.clearTemporaryFiles().catchError((_) {}));
    }
  }

  /// Loads the file without playing it. Throws if the phone can't play it.
  /// Returns its length when known.
  static Future<Duration?> probe(String path) async {
    final player = AudioPlayer();
    try {
      await player
          .setSource(DeviceFileSource(path))
          .timeout(const Duration(seconds: 15));
      final d = await player.getDuration();
      return d == null || d <= Duration.zero ? null : d;
    } finally {
      await player.dispose();
    }
  }

  /// Deletes picked files that no setting or point uses any more
  /// (for example after choosing a different sound).
  Future<void> cleanUp(Set<String> inUse) async {
    final dir = _dir;
    if (dir == null) return;
    for (final name in _files.difference(inUse).toList()) {
      await _delete(File('${dir.path}${Platform.pathSeparator}$name'));
      _files.remove(name);
    }
  }

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('Could not delete ${f.path}: $e');
    }
  }

  static String _baseName(String path) =>
      path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);
}
