import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models/app_settings.dart';
import 'models/custom_sound.dart';
import 'models/speed_point.dart';
import 'services/alert_engine.dart';
import 'services/api_client.dart';
import 'services/location_service.dart';
import 'services/sound_library.dart';
import 'services/storage.dart';
import 'services/sync_service.dart';
import 'services/voice_player.dart';

/// Holds the app state and connects GPS -> warning logic -> voice, and the
/// phone -> server sync.
class AppController extends ChangeNotifier implements SyncHost {
  AppController({
    Storage? storage,
    LocationService? location,
    VoicePlayer? voice,
    ApiClient? api,
  }) : _storage = storage ?? Storage(),
       _location = location ?? LocationService(),
       voice = voice ?? VoicePlayer() {
    sync = SyncService(api: api ?? ApiClient(), storage: _storage, host: this)
      ..addListener(notifyListeners);
  }

  final Storage _storage;
  final LocationService _location;
  final VoicePlayer voice;
  final AlertEngine _engine = AlertEngine();

  /// Online backup, community map, votes and reports.
  late final SyncService sync;

  /// Points I added (synced to my account).
  List<SpeedPoint> _points = [];

  /// Points added by other drivers (downloaded, kept for offline use).
  List<SpeedPoint> _community = [];
  List<SpeedPoint>? _mapPoints;

  AppSettings _settings = const AppSettings();
  DriveSample? _position;

  /// The position came from the GPS now (not a saved one from before).
  bool _liveFix = false;
  DriveSample? _lastRealPosition;
  bool _lastRealLive = false;
  ActiveAlert? _active;
  Upcoming? _next;
  LocationStatus? _locationStatus;
  SpeedPoint? _simulating;
  bool _ready = false;

  StreamSubscription<DriveSample>? _gpsSub;
  StreamSubscription<DriveSample>? _simSub;

  /// My points.
  List<SpeedPoint> get points => List.unmodifiable(_points);

  /// Points from other drivers.
  List<SpeedPoint> get community => List.unmodifiable(_community);

  /// Everything that warns and shows on the map: mine + community.
  List<SpeedPoint> get mapPoints => _mapPoints ??= () {
    final mine = {
      for (final p in _points)
        if (p.remoteId != null) p.remoteId,
    };
    return List<SpeedPoint>.unmodifiable([
      ..._points,
      ..._community.where((c) => !mine.contains(c.remoteId)),
    ]);
  }();

  @override
  AppSettings get settings => _settings;
  DriveSample? get position => _position;

  /// The driver's position from the GPS right now, or null while waiting
  /// for a fix (an old saved position is not "my location").
  DriveSample? get livePosition => _liveFix && !isSimulating ? _position : null;
  ActiveAlert? get active => _active;

  /// Next camera / bump further up the road (within 10 km).
  Upcoming? get next => _next;
  LocationStatus? get locationStatus => _locationStatus;
  bool get isSimulating => _simulating != null;
  bool get ready => _ready;

  /// Direction of travel used by the warnings (null until we move).
  double? get course => _engine.course;

  /// Sound files the user picked (audio or video).
  SoundLibrary get sounds => voice.sounds;

  Future<void> init() async {
    _points = await _storage.loadPoints();
    _community = await _storage.loadCommunity();
    _mapPoints = null;
    _settings = await _storage.loadSettings();
    voice.settings = _settings;
    await voice.init();
    // Remove sound files left over from sounds that were replaced.
    unawaited(sounds.cleanUp(_soundFilesInUse()));
    _applyWakelock();
    _position = await _location.lastKnown();
    _ready = true;
    notifyListeners();
    await sync.start();
    await startGps();
  }

  /// Starts the GPS. [ask] shows the permission prompt if needed (only
  /// when the driver asked for it, or on first start).
  Future<void> startGps({bool ask = true}) async {
    _locationStatus = await _location.ensurePermission(ask: ask);
    notifyListeners();
    if (_locationStatus != LocationStatus.ok) return;
    await _gpsSub?.cancel();
    _gpsSub = _location.gps().listen(
      (s) {
        if (isSimulating) {
          // Remember it for when the test drive ends.
          _lastRealPosition = s;
          _lastRealLive = true;
          return;
        }
        _liveFix = true;
        _onSample(s);
      },
      onError: (Object e) {
        debugPrint('GPS error: $e');
        _locationStatus = LocationStatus.serviceOff;
        notifyListeners();
      },
    );
  }

  Future<void> openLocationSettings() => _location.openSettings();

  void _onSample(DriveSample s) {
    _position = s;
    final all = mapPoints;
    final result = _engine.update(s, all, _settings);
    _active = result.active;
    _next = _engine.nextAhead(s, all);
    result.events.forEach(voice.announce);
    if (!isSimulating) sync.positionChanged(s.lat, s.lng);
    notifyListeners();
  }

  void _pointsChanged() {
    _mapPoints = null;
    final ids = {for (final p in mapPoints) p.id};
    if (_active != null && !ids.contains(_active!.point.id)) _active = null;
    if (_next != null && !ids.contains(_next!.point.id)) _next = null;
    notifyListeners();
  }

  // ---- My points --------------------------------------------------------

  Future<void> addPoint(SpeedPoint p) async {
    _points = [..._points, p.copyWith(dirty: true)];
    _pointsChanged();
    await _storage.savePoints(_points);
    sync.localChange();
  }

  /// Saves a changed point. Only the fields a driver can change are taken
  /// from [p]; its server id and vote counts stay as they are now (a sync
  /// may have updated them while the editor was open). For a community
  /// point only this phone's sound and repeat change.
  Future<void> updatePoint(SpeedPoint p) async {
    if (p.community) {
      _community = [
        for (final x in _community)
          x.id == p.id
              ? x.copyWith(sound: () => p.sound, repeat: () => p.repeat)
              : x,
      ];
      _pointsChanged();
      await _storage.saveCommunity(_community);
      return;
    }
    _points = [
      for (final x in _points)
        x.id == p.id
            ? x.copyWith(
                type: p.type,
                lat: p.lat,
                lng: p.lng,
                speedLimit: () => p.speedLimit,
                direction: () => p.direction,
                note: () => p.note,
                sound: () => p.sound,
                repeat: () => p.repeat,
                shared: p.shared,
                dirty: true,
              )
            : x,
    ];
    _pointsChanged();
    await _storage.savePoints(_points);
    sync.localChange();
  }

  Future<void> deletePoint(String id) async {
    final gone = _points.where((p) => p.id == id).firstOrNull;
    _points = _points.where((p) => p.id != id).toList();
    _pointsChanged();
    await _storage.savePoints(_points);
    if (gone?.remoteId case final remoteId?) sync.queueDelete(remoteId);
  }

  /// Adds points from pasted text. Points already on the map (same spot
  /// within ~10 m and same type) are skipped. Returns how many were added.
  Future<int> importPoints(String text) async {
    final incoming = parsePoints(text);
    final added = <SpeedPoint>[];
    for (final p in incoming) {
      final dup = [...mapPoints, ...added].any(
        (q) =>
            q.type == p.type &&
            (q.lat - p.lat).abs() < 0.0001 &&
            (q.lng - p.lng).abs() < 0.0001,
      );
      if (dup) continue;
      // A fresh copy: the list may come from another phone or account.
      // Shared only if the driver shares new points.
      added.add(
        p
            .asNewLocal(newPointId())
            .copyWith(shared: p.shared && _settings.sharePoints),
      );
    }
    if (added.isNotEmpty) {
      _points = [..._points, ...added];
      _pointsChanged();
      await _storage.savePoints(_points);
      sync.localChange();
    }
    return added.length;
  }

  String exportAll() => exportPoints(_points);

  /// Deletes all my points (here and from my account).
  Future<void> deleteAll() async {
    final remote = [for (final p in _points) ?p.remoteId];
    _points = [];
    _pointsChanged();
    await _storage.savePoints(_points);
    remote.forEach(sync.queueDelete);
  }

  /// Undo of [deletePoint]: puts the point back.
  Future<void> restorePoint(SpeedPoint p) async {
    if (_points.any((x) => x.id == p.id)) return;
    final remoteId = p.remoteId;
    // Still on the server if the delete hadn't been sent; otherwise it is
    // uploaded again as a new point.
    final kept = remoteId != null && sync.cancelDelete(remoteId);
    _points = [
      ..._points,
      kept ? p : p.copyWith(remoteId: () => null, dirty: true),
    ];
    _pointsChanged();
    await _storage.savePoints(_points);
    if (!kept) sync.localChange();
  }

  // ---- Community --------------------------------------------------------

  /// "Still there" / "Gone" on another driver's point (null takes it back).
  /// Returns the updated point, or null when it is now hidden.
  Future<SpeedPoint?> vote(SpeedPoint p, String? vote) => sync.vote(p, vote);

  Future<void> report(SpeedPoint p, String reason, String? comment) =>
      sync.report(p, reason, comment);

  // ---- SyncHost ---------------------------------------------------------

  @override
  List<SpeedPoint> get myPoints => _points;

  @override
  List<SpeedPoint> get communityPoints => _community;

  @override
  ({double lat, double lng})? get syncPosition {
    final p = _position;
    return p == null ? null : (lat: p.lat, lng: p.lng);
  }

  @override
  Future<void> setMyPoints(List<SpeedPoint> points) async {
    _points = points;
    _pointsChanged();
    await _storage.savePoints(_points);
  }

  @override
  Future<void> setCommunity(List<SpeedPoint> points) async {
    _community = points;
    _pointsChanged();
    await _storage.saveCommunity(_community);
  }

  @override
  Future<void> restoreSettings(AppSettings settings) =>
      _setSettings(settings, backup: false);

  // ---- Settings ---------------------------------------------------------

  Future<void> updateSettings(AppSettings s) => _setSettings(s, backup: true);

  Future<void> _setSettings(AppSettings s, {required bool backup}) async {
    final mutedNow = s.muted && !_settings.muted;
    final backupChanged = !mapEquals(
      s.toBackupJson().map((k, v) => MapEntry(k, v.toString())),
      _settings.toBackupJson().map((k, v) => MapEntry(k, v.toString())),
    );
    _settings = s;
    voice.settings = s;
    if (mutedNow) unawaited(voice.stopAll());
    _applyWakelock();
    notifyListeners();
    await _storage.saveSettings(s);
    if (backup && backupChanged) sync.settingsChanged();
  }

  Future<void> toggleMute() =>
      updateSettings(_settings.copyWith(muted: !_settings.muted));

  /// Sets your sound for one warning slot (see `SoundSlot`); null goes back
  /// to the default.
  Future<void> setSound(String slot, CustomSound? sound) =>
      updateSettings(_settings.withSound(slot, sound));

  /// How many times a warning group plays ("camera", "bump", "over_speed").
  Future<void> setRepeat(String group, int times) =>
      updateSettings(_settings.withRepeat(group, times));

  Set<String> _soundFilesInUse() => {
    for (final s in _settings.sounds.values) s.file,
    for (final p in [..._points, ..._community])
      if (p.sound case final s?) s.file,
  };

  void _applyWakelock() {
    unawaited(
      WakelockPlus.toggle(enable: _settings.keepScreenOn).catchError((_) {}),
    );
  }

  // ---- Test drive -------------------------------------------------------

  /// Pretends to drive past [p] so you can hear the warnings at home.
  /// Drives 20 km/h over the limit so the "slow down" warning plays too.
  double startSimulation(SpeedPoint p) {
    stopSimulation();
    _lastRealPosition = _position;
    _lastRealLive = _liveFix;
    final kmh = ((p.speedLimit ?? 60) + 20).toDouble();
    _engine.reset();
    _simulating = p;
    _simSub = simulateDrive(
      p,
      kmh: kmh,
    ).listen(_onSample, onDone: stopSimulation);
    notifyListeners();
    return kmh;
  }

  void stopSimulation() {
    if (_simulating == null) return;
    _simSub?.cancel();
    _simSub = null;
    _simulating = null;
    _active = null;
    _next = null;
    _engine.reset();
    // Back to the real position (not the last pretend one).
    _position = _lastRealPosition;
    _liveFix = _lastRealLive;
    notifyListeners();
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _simSub?.cancel();
    sync.dispose();
    voice.dispose();
    super.dispose();
  }
}
