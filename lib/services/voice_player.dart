import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../models/app_settings.dart';
import '../models/custom_sound.dart';
import '../models/speed_point.dart';
import 'alert_engine.dart';
import 'sound_library.dart';
import 'sound_resolver.dart';

/// Plays the warning voices, one after another (never on top of each other).
///
/// For each warning it uses, in this order (see [resolveSound]):
///  1. the point's own sound (set when editing that point),
///  2. the sound you picked in Settings (audio, or the sound of a video),
///  3. a built-in recording in `assets/sounds/`:
///       camera_500.mp3, camera_300.mp3, ... bump_300.mp3, bump_100.mp3
///       camera.mp3 / bump.mp3  (used for any distance without its own file)
///       over_speed.mp3
///  4. the phone's text-to-speech voice.
/// Each warning plays as many times as set in Settings (or on the point).
class VoicePlayer {
  static const _dir = 'assets/sounds/';
  static const _extensions = ['mp3', 'm4a', 'wav', 'ogg', 'aac'];
  static const _gapBetweenRepeats = Duration(milliseconds: 450);
  static const _previewId = 'preview';

  late final AudioPlayer _player = AudioPlayer(playerId: 'warnings');
  late final FlutterTts _tts = FlutterTts();

  /// Sound files picked by the user.
  final SoundLibrary sounds = SoundLibrary();

  final List<_Utterance> _queue = [];
  Set<String> _assets = {};
  bool _busy = false;
  _Utterance? _current;
  Completer<void> _skip = Completer<void>();

  /// Kept up to date by the app controller.
  AppSettings settings = const AppSettings();
  bool get muted => settings.muted;

  Future<void> init() async {
    await sounds.init();
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      _assets = manifest.listAssets().where((a) => a.startsWith(_dir)).toSet();
    } catch (_) {
      _assets = {};
    }

    // Lower music / other apps while a warning plays, like a navigation app.
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            usageType: AndroidUsageType.assistanceNavigationGuidance,
            contentType: AndroidContentType.speech,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: const {
              AVAudioSessionOptions.duckOthers,
              AVAudioSessionOptions.interruptSpokenAudioAndMixWithOthers,
            },
          ),
        ),
      );
      await _player.setReleaseMode(ReleaseMode.stop);
    } catch (e) {
      debugPrint('Audio setup failed: $e');
    }

    try {
      await _tts.awaitSpeakCompletion(true);
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _tts.setSharedInstance(true);
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          const [
            IosTextToSpeechAudioCategoryOptions.duckOthers,
            IosTextToSpeechAudioCategoryOptions
                .interruptSpokenAudioAndMixWithOthers,
          ],
          IosTextToSpeechAudioMode.voicePrompt,
        );
      }
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
    } catch (e) {
      debugPrint('TTS setup failed: $e');
    }
  }

  /// Which recorded files were found (for the settings screen).
  List<String> get recordedFiles =>
      (_assets
              .where((a) => _extensions.any((e) => a.endsWith('.$e')))
              .map((a) => a.substring(_dir.length)))
          .toList()
        ..sort();

  /// True if the app has a built-in recording for this slot.
  bool hasRecording(String slot) => _findAsset(slot) != null;

  /// What would play for these slots (most specific first), with the
  /// point's own sound [own] taking priority.
  ResolvedSound resolve(List<String> slots, {CustomSound? own}) =>
      resolveSound(
        slots: slots,
        own: own,
        userSounds: settings.sounds,
        fileExists: sounds.has,
        assetFor: _findAsset,
      );

  void announce(AlertEvent e) {
    if (muted) return;
    final p = e.point;
    switch (e.kind) {
      case AlertEventKind.approach:
        final limit = p.type == PointType.camera && p.speedLimit != null
            ? ' Limit ${p.speedLimit}.'
            : '';
        _enqueue(
          _utterance(
            pointId: p.id,
            kind: 'approach',
            sound: resolve(
              SoundSlot.forApproach(p.type, e.distance),
              own: p.sound,
            ),
            text: '${p.type.label} in ${e.distance} meters.$limit',
            repeat: p.repeat ?? settings.repeatFor(SoundSlot.type(p.type)),
          ),
        );
      case AlertEventKind.overSpeed:
        _enqueue(
          _utterance(
            pointId: p.id,
            kind: 'speed',
            sound: resolve(const [SoundSlot.overSpeed]),
            text: p.speedLimit != null
                ? 'Slow down! Speed limit ${p.speedLimit}.'
                : 'Slow down!',
            repeat: settings.repeatFor(SoundSlot.overSpeed),
          ),
        );
    }
  }

  /// Plays one slot by name (e.g. "camera_300"), for testing in settings.
  void preview(String name, String fallbackText) =>
      previewSound(slots: [name], text: fallbackText);

  /// Plays what a warning would sound like (Settings and the point editor).
  /// A new preview stops the one playing.
  void previewSound({
    required List<String> slots,
    CustomSound? own,
    required String text,
    int repeat = 1,
  }) {
    _queue.removeWhere((q) => q.pointId == _previewId);
    if (_current?.pointId == _previewId) _skipCurrent();
    _enqueue(
      _utterance(
        pointId: _previewId,
        kind: 'preview',
        sound: resolve(slots, own: own),
        text: text,
        repeat: repeat,
      ),
    );
  }

  _Utterance _utterance({
    required String pointId,
    required String kind,
    required ResolvedSound sound,
    required String text,
    required int repeat,
  }) {
    final custom = sounds.pathOf(sound.custom);
    return _Utterance(
      pointId: pointId,
      kind: kind,
      text: text,
      source: custom != null
          ? DeviceFileSource(custom)
          // AssetSource paths are relative to "assets/".
          : sound.asset != null
          ? AssetSource(sound.asset!.substring('assets/'.length))
          : null,
      repeat: repeat.clamp(1, maxRepeat),
    );
  }

  String? _findAsset(String name) {
    for (final ext in _extensions) {
      final path = '$_dir$name.$ext';
      if (_assets.contains(path)) return path;
    }
    return null;
  }

  void _enqueue(_Utterance u) {
    // A newer warning of the same kind for the same point replaces an older
    // one still waiting.
    _queue.removeWhere((q) => q.key == u.key);
    _queue.add(u);
    if (_queue.length > 3) _queue.removeAt(0);
    unawaited(_drain());
  }

  void _skipCurrent() {
    if (!_skip.isCompleted) _skip.complete();
  }

  Future<void> _drain() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty) {
        final u = _current = _queue.removeAt(0);
        _skip = Completer<void>();
        for (var i = 0; i < u.repeat; i++) {
          if (i > 0) {
            // Stop repeating when a newer warning for this point is waiting
            // (e.g. 300 m was reached while 500 m is still repeating).
            if (_queue.any((q) => q.pointId == u.pointId)) break;
            await Future.any([
              Future<void>.delayed(_gapBetweenRepeats),
              _skip.future,
            ]);
          }
          if (_skip.isCompleted) break;
          await _playOnce(u);
        }
        _current = null;
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _playOnce(_Utterance u) async {
    try {
      final source = u.source;
      if (source == null) {
        await Future.any([_tts.speak(u.text), _skip.future]);
        if (_skip.isCompleted) await _tts.stop();
        return;
      }
      final done = _player.onPlayerComplete.first;
      await _player.play(source);
      // Long sounds (e.g. a whole video) are cut so the next warning
      // isn't held up.
      var finished = false;
      await Future.any([
        done.then((_) => finished = true),
        _skip.future,
      ]).timeout(maxClipLength, onTimeout: () {});
      if (!finished) await _player.stop();
    } catch (e) {
      debugPrint('Could not play warning: $e');
    }
  }

  Future<void> stopAll() async {
    _queue.clear();
    _skipCurrent();
    await _player.stop();
    await _tts.stop();
  }

  Future<void> dispose() async {
    await stopAll();
    await _player.dispose();
  }
}

class _Utterance {
  const _Utterance({
    required this.pointId,
    required this.kind,
    required this.text,
    required this.repeat,
    this.source,
  });

  final String pointId;
  final String kind;

  /// Spoken by the phone voice when there is no [source].
  final String text;
  final Source? source;
  final int repeat;

  String get key => '$pointId#$kind';
}
