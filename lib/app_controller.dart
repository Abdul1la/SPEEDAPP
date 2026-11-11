import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models/app_settings.dart';
import 'models/custom_sound.dart';
import 'models/route_plan.dart';
import 'models/speed_point.dart';
import 'services/alert_engine.dart';
import 'services/api_client.dart';
import 'services/location_service.dart';
import 'services/slowdown_detector.dart';
import 'services/sound_library.dart';
import 'services/storage.dart';
import 'services/sync_service.dart';
import 'services/voice_player.dart';
import 'utils/geo.dart';

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
       voice = voice ?? VoicePlayer(),
       _api = api ?? ApiClient() {
    sync = SyncService(api: _api, storage: _storage, host: this)
      ..addListener(notifyListeners);
  }

  final ApiClient _api;

  final Storage _storage;
  final LocationService _location;
  final VoicePlayer voice;
  final AlertEngine _engine = AlertEngine();

  /// Online backup, community map and votes.
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

  // ---- Police radar ----
  final SlowdownDetector _slowdowns = SlowdownDetector();
  Timer? _expiryTimer;

  /// The police radar the driver is passing now (within [_passRadiusM]).
  SpeedPoint? _passing;

  /// The police radar just passed: "still there?" is shown for [askFor].
  SpeedPoint? _askStillThere;
  Timer? _askTimer;

  /// When each radar was last asked about (not again for [_askAgainAfter]).
  final Map<String, DateTime> _asked = {};
  static const _passRadiusM = 80.0;
  static const _passedRadiusM = 150.0;
  static const _askAgainAfter = Duration(minutes: 30);
  static const askFor = Duration(seconds: 15);

  /// Braking near a fixed camera or bump is explained by it.
  static const _explainedWithinM = 200.0;

  /// My points.
  List<SpeedPoint> get points => List.unmodifiable(_points);

  /// Points from other drivers.
  List<SpeedPoint> get community => List.unmodifiable(_community);

  /// Everything that warns and shows on the map: mine + community.
  List<SpeedPoint> get mapPoints => _mapPoints ??= () {
    final now = DateTime.now();
    final mine = {
      for (final p in _points)
        if (p.remoteId != null) p.remoteId,
    };
    final shown = <String?>{...mine};
    return List<SpeedPoint>.unmodifiable([
      for (final p in _points)
        if (!p.isExpired(now)) p,
      for (final c in _community)
        if ((shown.add(c.remoteId) || c.remoteId == null) && !c.isExpired(now))
          c,
      // Cameras and bumps along the chosen route (also far away).
      for (final r in _routePoints)
        if (shown.add(r.remoteId) && !r.isExpired(now)) r,
    ]);
  }();

  /// A police radar the driver just drove past: the map asks "still
  /// there?" for a few seconds. Answer with [answerStillThere].
  SpeedPoint? get askStillThere => _askStillThere;

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
    // Everything saved loads at the same time (faster start).
    final (points, community, settings) = await (
      _storage.loadPoints(),
      _storage.loadCommunity(),
      _storage.loadSettings(),
    ).wait;
    _points = points;
    _community = community;
    _mapPoints = null;
    await _dropExpired();
    _expiryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_dropExpired()),
    );
    _settings = settings;
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
    _updateRouteProgress(s);
    final all = mapPoints;
    final result = _engine.update(s, all, _settings);
    // Standing still right at a point (parked there, or where it was
    // added): no "0 m" warning that never goes away.
    final a = result.active;
    _active = a != null && s.stationary && a.distance < AlertEngine.closeRange
        ? null
        : a;
    _next = _engine.nextAhead(s, all);
    result.events.forEach(voice.announce);
    if (!isSimulating) {
      sync.positionChanged(s.lat, s.lng);
      _checkSlowdown(s, all);
      _checkPassedRadar(s, all);
    }
    notifyListeners();
  }

  // ---- Police radar -------------------------------------------------------

  /// Sends a sudden slowdown (a likely police radar) unless a fixed camera
  /// or bump explains it, or the driver turned this off.
  void _checkSlowdown(DriveSample s, List<SpeedPoint> all) {
    if (!_settings.findRadar) return;
    final e = _slowdowns.add(s);
    if (e == null) return;
    final explained = all.any(
      (p) =>
          !p.type.temporary &&
          distanceMeters(p.lat, p.lng, e.lat, e.lng) < _explainedWithinM,
    );
    if (!explained) unawaited(sync.reportSlowdown(e));
  }

  /// After driving past another driver's police radar, ask "still there?"
  /// (once per radar every half hour). The answers keep the map accurate:
  /// "no" twice takes it away, "yes" keeps it longer.
  void _checkPassedRadar(DriveSample s, List<SpeedPoint> all) {
    for (final p in all) {
      if (!p.type.temporary || !p.community || p.remoteId == null) continue;
      if (distanceMeters(s.lat, s.lng, p.lat, p.lng) < _passRadiusM) {
        _passing = p;
        return;
      }
    }
    final passed = _passing;
    if (passed == null ||
        distanceMeters(s.lat, s.lng, passed.lat, passed.lng) < _passedRadiusM) {
      return;
    }
    _passing = null;
    final id = passed.remoteId!;
    final last = _asked[id];
    if (s.speedKmh < 10 ||
        (last != null && s.time.difference(last) < _askAgainAfter)) {
      return;
    }
    _asked[id] = s.time;
    _askStillThere = passed;
    _askTimer?.cancel();
    _askTimer = Timer(askFor, dismissStillThere);
  }

  /// "Still there?" answered: [yes] confirms it, no says it's gone.
  Future<void> answerStillThere(bool yes) async {
    final p = _askStillThere;
    dismissStillThere();
    if (p == null) return;
    try {
      await vote(p, yes ? 'confirm' : 'gone');
    } catch (e) {
      debugPrint('Could not send the answer: $e');
    }
  }

  void dismissStillThere() {
    _askTimer?.cancel();
    if (_askStillThere == null) return;
    _askStillThere = null;
    notifyListeners();
  }

  /// Police radar reports past their time leave the map (also offline).
  Future<void> _dropExpired() async {
    final now = DateTime.now();
    final mine = _points.where((p) => !p.isExpired(now)).toList();
    final community = _community.where((p) => !p.isExpired(now)).toList();
    final routeChanged = _routePoints.any((p) => p.isExpired(now));
    if (mine.length == _points.length &&
        community.length == _community.length &&
        !routeChanged) {
      return;
    }
    _points = mine;
    _community = community;
    _pointsChanged();
    await _storage.savePoints(_points);
    await _storage.saveCommunity(_community);
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

  /// Tests: a GPS fix without a phone.
  @visibleForTesting
  void debugGpsFix(DriveSample s) {
    _liveFix = true;
    _onSample(s);
  }

  // ---- Search and directions -------------------------------------------

  Place? _destination;
  List<RouteOption> _routeOptions = const [];
  int _selectedRoute = 0;
  bool _routeActive = false;
  List<SpeedPoint> _routePoints = const [];
  double? _remainingM;
  bool _offRoute = false;
  DateTime? _offRouteSince;
  int _routeHint = 0;
  final _messages = StreamController<String>.broadcast();

  /// Where the driver is going (while choosing or driving a route).
  Place? get destination => _destination;

  /// The ways to drive there, fastest first.
  List<RouteOption> get routeOptions => _routeOptions;
  int get selectedRoute => _selectedRoute;
  RouteOption? get route =>
      _routeOptions.isEmpty ? null : _routeOptions[_selectedRoute];

  /// Driving the chosen route (not just looking at the options).
  bool get routeActive => _routeActive;

  /// Where on the route's path the driver is now (index into its points).
  int get routeIndex => _routeHint;

  /// Meters left to drive, and the normal time for them.
  double? get remainingM => _remainingM;
  int? get remainingS {
    final r = route;
    final m = _remainingM;
    if (r == null || m == null || r.distanceM == 0) return null;
    return (r.durationS * m / r.distanceM).round();
  }

  /// More than [offRouteM] away from the route for a while.
  bool get offRoute => _offRoute;
  static const offRouteM = 80.0;
  static const arrivedM = 40.0;

  /// One-off messages for the screen ("You have arrived").
  Stream<String> get messages => _messages.stream;

  /// Search for places (search as you type): Iraq first, nearest to the
  /// driver first. One [session] per search screen (see [resolvePlace]).
  Future<List<Place>> searchPlaces(String query, {String? session}) async {
    await sync.ensureAccount();
    final p = _position;
    return _api.places(query, lat: p?.lat, lng: p?.lng, session: session);
  }

  /// A search result with its spot on the map. Google results come without
  /// one; this asks the server (ending the search [session]).
  Future<Place> resolvePlace(Place place, {String? session}) async {
    if (place.located) return place;
    await sync.ensureAccount();
    return place.locatedAt(await _api.place(place.id, session: session));
  }

  /// Gets the ways to drive from here to [to]. Throws [ApiException] when
  /// offline, without GPS, or when no road leads there.
  Future<void> planRoute(Place to) async {
    final from = livePosition ?? _position;
    if (from == null) {
      throw const ApiException(0, 'no_gps', 'Waiting for your GPS position…');
    }
    await sync.ensureAccount();
    final json = await _api.routes(from.lat, from.lng, to.lat, to.lng);
    final options = [
      for (final r in (json['routes'] as List).cast<Map<String, dynamic>>())
        RouteOption.fromJson(r),
    ];
    final points = [
      for (final p in (json['points'] as List).cast<Map<String, dynamic>>())
        SpeedPoint.fromServer(p),
    ];
    _destination = to;
    _routeOptions = options;
    _selectedRoute = 0;
    _routeActive = false;
    _remainingM = null;
    _offRoute = false;
    _routePoints = points;
    _pointsChanged();
  }

  void selectRoute(int index) {
    if (index < 0 || index >= _routeOptions.length) return;
    _selectedRoute = index;
    notifyListeners();
  }

  /// Starts driving the chosen route.
  void startRoute() {
    if (route == null) return;
    _routeActive = true;
    _routeHint = 0;
    _offRoute = false;
    _offRouteSince = null;
    final p = livePosition ?? _position;
    if (p != null) _updateRouteProgress(p);
    notifyListeners();
  }

  /// Stops the route (or the choosing) and removes it from the map.
  void endRoute() {
    if (_destination == null && _routeOptions.isEmpty) return;
    _destination = null;
    _routeOptions = const [];
    _routeActive = false;
    _remainingM = null;
    _offRoute = false;
    _routePoints = const [];
    _pointsChanged();
  }

  /// Plans the route again from here (after leaving it).
  Future<void> reroute() async {
    final to = _destination;
    if (to == null) return;
    await planRoute(to);
    startRoute();
  }

  void _updateRouteProgress(DriveSample s) {
    final r = route;
    if (!_routeActive || r == null) return;
    final progress = r.progress(s.lat, s.lng, hint: _routeHint);
    _routeHint = progress.index;
    _remainingM = progress.remainingM;
    final dest = _destination;
    final atDestination =
        dest != null &&
        distanceMeters(s.lat, s.lng, dest.lat, dest.lng) < arrivedM;
    if (atDestination ||
        (progress.remainingM < arrivedM && progress.offRouteM < offRouteM)) {
      final name = dest?.name;
      endRoute();
      _messages.add(
        name == null ? 'You have arrived' : 'You have arrived at $name',
      );
      return;
    }
    // Off the route for 15 s (not just a GPS jump): offer a new route.
    if (progress.offRouteM > offRouteM) {
      _offRouteSince ??= s.time;
      _offRoute = s.time.difference(_offRouteSince!).inSeconds >= 15;
    } else {
      _offRouteSince = null;
      _offRoute = false;
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _askTimer?.cancel();
    _messages.close();
    _gpsSub?.cancel();
    _simSub?.cancel();
    sync.dispose();
    voice.dispose();
    super.dispose();
  }
}
