import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../models/speed_point.dart';
import '../utils/geo.dart';
import 'api_client.dart';
import 'storage.dart';

/// What the sync service needs from the app (implemented by AppController).
abstract interface class SyncHost {
  List<SpeedPoint> get myPoints;
  List<SpeedPoint> get communityPoints;
  AppSettings get settings;

  /// Where the driver is now (null before the first GPS fix).
  ({double lat, double lng})? get syncPosition;

  Future<void> setMyPoints(List<SpeedPoint> points);
  Future<void> setCommunity(List<SpeedPoint> points);
  Future<void> restoreSettings(AppSettings settings);
}

/// The signed-in account (null email = anonymous, this phone only).
class Account {
  const Account({required this.id, this.email});
  final String id;
  final String? email;
  bool get isAnonymous => email == null;

  Map<String, dynamic> toJson() => {'id': id, 'email': email};
  static Account? fromJson(Object? json) => json is Map<String, dynamic>
      ? Account(id: json['id'] as String, email: json['email'] as String?)
      : null;
}

/// Keeps this phone and the server in step. The phone always works offline:
/// every change is saved locally first, marked `dirty`, and uploaded when
/// there is a connection.
///  * My points: uploaded (created / changed / deleted), restored on sign-in.
///  * Community points: downloaded around the driver (30 km), then only
///    changes ("since"), and kept for offline use.
///  * Settings: backed up to the account (not the sound files).
class SyncService extends ChangeNotifier {
  SyncService({required this.api, required this.storage, required this.host});

  final ApiClient api;
  final Storage storage;
  final SyncHost host;

  static const areaRadiusKm = 30.0;

  /// Download the area again when the driver is this far from its center.
  static const refetchDistanceM = 10000.0;
  static const fullRefreshAfter = Duration(hours: 24);
  static const syncEvery = Duration(minutes: 10);
  static const _debounce = Duration(seconds: 3);

  // Saved state
  String? _token;
  Account? _account;
  String? _signedOutEmail;
  String? _cursor;
  double? _centerLat;
  double? _centerLng;
  DateTime? _fetchedAt;
  DateTime? _lastSyncAt;
  final Set<String> _pendingDeletes = {};
  bool _settingsDirty = false;

  // Runtime state
  bool _started = false;
  bool _syncing = false;
  bool _again = false;
  String? _error;
  Timer? _timer;
  Timer? _soon;

  Account? get account => _account;

  /// Set when the server signed this phone out (e.g. password changed).
  String? get signedOutEmail => _signedOutEmail;
  bool get syncing => _syncing;
  DateTime? get lastSyncAt => _lastSyncAt;

  /// The last problem (offline, server error...), or null.
  String? get error => _error;

  /// Changes on this phone not uploaded yet.
  int get pending =>
      host.myPoints.where((p) => p.dirty).length + _pendingDeletes.length;

  String get _deviceName =>
      kIsWeb ? 'Web' : '${Platform.operatingSystem} phone';

  // ---- Lifecycle ----

  Future<void> start() async {
    if (_started) return;
    final s = await storage.loadSyncState() ?? const {};
    _token = s['token'] as String?;
    _account = Account.fromJson(s['account']);
    _signedOutEmail = s['signedOutEmail'] as String?;
    _cursor = s['cursor'] as String?;
    _centerLat = (s['centerLat'] as num?)?.toDouble();
    _centerLng = (s['centerLng'] as num?)?.toDouble();
    _fetchedAt = DateTime.tryParse(s['fetchedAt'] as String? ?? '');
    _lastSyncAt = DateTime.tryParse(s['lastSyncAt'] as String? ?? '');
    _pendingDeletes.addAll(
      (s['pendingDeletes'] as List?)?.cast<String>() ?? [],
    );
    _settingsDirty = s['settingsDirty'] as bool? ?? false;
    api.token = _token;
    _started = true;
    _timer = Timer.periodic(syncEvery, (_) => unawaited(syncNow()));
    unawaited(syncNow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _soon?.cancel();
    super.dispose();
  }

  Future<void> _save() => storage.saveSyncState({
    'token': _token,
    'account': _account?.toJson(),
    'signedOutEmail': _signedOutEmail,
    'cursor': _cursor,
    'centerLat': _centerLat,
    'centerLng': _centerLng,
    'fetchedAt': _fetchedAt?.toIso8601String(),
    'lastSyncAt': _lastSyncAt?.toIso8601String(),
    'pendingDeletes': _pendingDeletes.toList(),
    'settingsDirty': _settingsDirty,
  });

  // ---- Triggers from the app ----

  /// My points changed: upload soon.
  void localChange() {
    if (!_started) return;
    notifyListeners();
    _soon?.cancel();
    _soon = Timer(_debounce, () => unawaited(syncNow(pull: false)));
  }

  /// A point with this server id was deleted on the phone.
  void queueDelete(String remoteId) {
    _pendingDeletes.add(remoteId);
    if (_started) unawaited(_save());
    localChange();
  }

  void settingsChanged() {
    _settingsDirty = true;
    if (!_started) return;
    unawaited(_save());
    localChange();
  }

  /// The driver moved: download a new area when far from the last one.
  void positionChanged(double lat, double lng) {
    if (!_started || _syncing) return;
    final cLat = _centerLat;
    final cLng = _centerLng;
    if (cLat == null ||
        cLng == null ||
        distanceMeters(cLat, cLng, lat, lng) > refetchDistanceM) {
      unawaited(syncNow());
    }
  }

  // ---- Sync ----

  Future<bool>? _running;

  /// Uploads local changes, then (with [pull]) downloads the community map.
  /// If a sync is already running, waits for it and then runs again (so
  /// changes made meanwhile are included). Returns false when it couldn't
  /// finish (see [error]).
  Future<bool> syncNow({bool pull = true}) async {
    if (!_started) return false;
    while (_running != null) {
      await _running;
    }
    final run = _run(pull);
    _running = run;
    try {
      return await run;
    } finally {
      if (identical(_running, run)) _running = null;
    }
  }

  Future<bool> _run(bool pull) async {
    _syncing = true;
    notifyListeners();
    var ok = false;
    try {
      await _ensureAccount();
      if (_token != null) {
        await _pushDeletes();
        await _pushPoints();
        await _pushSettings();
        if (pull) await _pull();
        _lastSyncAt = DateTime.now();
        _error = null;
        ok = true;
      }
    } on ApiException catch (e) {
      await _onError(e);
    } catch (e) {
      debugPrint('Sync failed: $e');
      _error = 'Sync failed. It will try again.';
    } finally {
      _syncing = false;
      await _save();
      notifyListeners();
      if (_again) {
        _again = false;
        unawaited(syncNow());
      }
    }
    return ok;
  }

  Future<void> _onError(ApiException e) async {
    if (e.offline) {
      _error = 'Offline. Changes are saved and will upload later.';
    } else if (e.status == 401) {
      // The server doesn't know this sign-in any more.
      final email = _account?.email;
      _setSignedOut();
      if (email != null) {
        _signedOutEmail = email;
        _error = 'You were signed out. Sign in again to keep backing up.';
      } else {
        // An anonymous account can just start over: upload everything again.
        await host.setMyPoints([
          for (final p in host.myPoints)
            p.copyWith(remoteId: () => null, dirty: true),
        ]);
        _pendingDeletes.clear();
        _error = null;
        _again = true;
      }
    } else if (e.code == 'banned') {
      _error = e.message;
    } else {
      _error = e.message;
    }
  }

  void _setSignedOut() {
    _token = null;
    _account = null;
    api.token = null;
    _cursor = null;
  }

  void _setAccount(Map<String, dynamic> res) {
    _token = res['token'] as String;
    api.token = _token;
    final user = res['user'] as Map<String, dynamic>;
    _account = Account(
      id: user['id'] as String,
      email: user['email'] as String?,
    );
    _signedOutEmail = null;
    _error = null;
  }

  Future<void> _ensureAccount() async {
    if (_token != null || _signedOutEmail != null) return;
    _setAccount(await api.anonymous(_deviceName));
    await _save();
  }

  Future<void> _pushDeletes() async {
    for (final id in _pendingDeletes.toList()) {
      try {
        await api.deletePoint(id);
      } on ApiException catch (e) {
        if (e.status != 404 && e.status != 403) rethrow;
      }
      _pendingDeletes.remove(id);
    }
  }

  /// Applies [change] to my point [id] in the current list (the user may
  /// have edited it meanwhile). Returning null removes it.
  Future<void> _updateMine(
    String id,
    SpeedPoint? Function(SpeedPoint) change,
  ) async {
    final list = <SpeedPoint>[];
    for (final p in host.myPoints) {
      if (p.id != id) {
        list.add(p);
      } else if (change(p) case final SpeedPoint next) {
        list.add(next);
      }
    }
    await host.setMyPoints(list);
  }

  static bool _sameOnServer(SpeedPoint a, SpeedPoint b) =>
      mapEquals(a.toServerJson(), b.toServerJson());

  Future<void> _pushPoints() async {
    for (final sent in host.myPoints.where((p) => p.dirty).toList()) {
      final remoteId = sent.remoteId;
      if (remoteId == null) {
        final res = await api.createPoint({
          ...sent.toServerJson(),
          'clientId': sent.id,
        });
        await _applyCreated(sent, res);
        continue;
      }
      try {
        await api.updatePoint(remoteId, sent.toServerJson());
        await _updateMine(
          sent.id,
          (now) => now.copyWith(dirty: !_sameOnServer(now, sent)),
        );
      } on ApiException catch (e) {
        if (e.status != 404 && e.status != 403) rethrow;
        // Removed by a moderator, or now owned by the community: keep it
        // on this phone only.
        await _updateMine(
          sent.id,
          (now) => now.copyWith(remoteId: () => null, dirty: false),
        );
      }
    }
  }

  Future<void> _applyCreated(SpeedPoint sent, Map<String, dynamic> res) async {
    final server = res['point'] as Map<String, dynamic>;
    final remoteId = server['id'] as String;
    final stillHere = host.myPoints.any((p) => p.id == sent.id);
    if (!stillHere) {
      // Deleted on the phone while uploading.
      if (server['mine'] == true) queueDelete(remoteId);
      return;
    }
    if (server['mine'] != true) {
      // Another driver already added it: it becomes that community point
      // (this upload counted as "still there"). Keep the phone's sound.
      final local = host.myPoints.firstWhere((p) => p.id == sent.id);
      await _updateMine(sent.id, (_) => null);
      final community = host.communityPoints.where(
        (c) => c.remoteId != remoteId,
      );
      await host.setCommunity([
        ...community,
        SpeedPoint.fromServer(
          server,
        ).copyWith(sound: () => local.sound, repeat: () => local.repeat),
      ]);
      return;
    }
    final duplicate = host.myPoints.any(
      (p) => p.id != sent.id && p.remoteId == remoteId,
    );
    await _updateMine(
      sent.id,
      (now) => duplicate
          ? null // the same point twice on this phone
          : now.copyWith(
              remoteId: () => remoteId,
              dirty: !_sameOnServer(now, sent),
            ),
    );
  }

  Future<void> _pushSettings() async {
    if (!_settingsDirty) return;
    await api.putSettings(host.settings.toBackupJson());
    _settingsDirty = false;
  }

  Future<void> _pull() async {
    final pos = host.syncPosition;
    if (pos == null) return;
    final cLat = _centerLat;
    final cLng = _centerLng;
    final fetched = _fetchedAt;
    final full =
        _cursor == null ||
        cLat == null ||
        cLng == null ||
        fetched == null ||
        DateTime.now().difference(fetched) > fullRefreshAfter ||
        distanceMeters(cLat, cLng, pos.lat, pos.lng) > refetchDistanceM;
    final res = await api.nearby(
      pos.lat,
      pos.lng,
      areaRadiusKm,
      since: full ? null : _cursor,
    );
    await _applyArea(
      (res['points'] as List).cast<Map<String, dynamic>>(),
      (res['removed'] as List).cast<String>(),
      replace: full,
    );
    _cursor = res['serverTime'] as String;
    if (full) {
      _centerLat = pos.lat;
      _centerLng = pos.lng;
      _fetchedAt = DateTime.now();
    }
  }

  /// Merges downloaded points: community ones into the cache; my own ones
  /// (e.g. added on my other phone) into my list unless changed here.
  Future<void> _applyArea(
    List<Map<String, dynamic>> points,
    List<String> removed, {
    required bool replace,
  }) async {
    final oldCommunity = {
      for (final c in host.communityPoints)
        if (c.remoteId != null) c.remoteId!: c,
    };
    final community = replace ? <String, SpeedPoint>{} : {...oldCommunity};
    final mine = [...host.myPoints];
    final mineByRemote = {
      for (var i = 0; i < mine.length; i++)
        if (mine[i].remoteId != null) mine[i].remoteId!: i,
    };
    var mineChanged = false;

    for (final json in points) {
      final id = json['id'] as String;
      if (json['mine'] == true) {
        if (_pendingDeletes.contains(id)) continue;
        final i = mineByRemote[id];
        if (i == null) {
          mine.add(SpeedPoint.fromServer(json));
          mineChanged = true;
        } else if (!mine[i].dirty) {
          mine[i] = SpeedPoint.fromServer(json, local: mine[i]);
          mineChanged = true;
        }
        community.remove(id);
      } else {
        community[id] = SpeedPoint.fromServer(json, local: oldCommunity[id]);
      }
    }
    for (final id in removed) {
      community.remove(id);
    }
    if (mineChanged) await host.setMyPoints(mine);
    await host.setCommunity(community.values.toList());
  }

  // ---- Account ----

  /// Backs up this phone's account with email + password (keeps everything).
  Future<void> register(String email, String password) async {
    await _ensureAccount();
    _setAccount(await api.register(email.trim(), password, _deviceName));
    _settingsDirty = true;
    await _save();
    notifyListeners();
    await syncNow();
  }

  /// Signs in to an existing account. What this phone added so far moves
  /// into that account; the account's points and settings come back here.
  Future<void> signIn(String email, String password) async {
    // Upload what's on this phone first, so the server can merge it.
    if (_signedOutEmail == null) await syncNow(pull: false);
    _setAccount(await api.login(email.trim(), password, _deviceName));
    await _save();
    notifyListeners();
    await _restoreFromAccount();
    _cursor = null; // votes etc. are per account: download the area again
    await syncNow();
  }

  Future<void> _restoreFromAccount() async {
    final server = await api.myPoints();
    final local = host.myPoints;
    final byRemote = {
      for (final p in local)
        if (p.remoteId != null) p.remoteId!: p,
    };
    final byId = {for (final p in local) p.id: p};
    final restored = <SpeedPoint>[];
    final used = <String>{};
    for (final json in server) {
      final match = byRemote[json['id']] ?? byId[json['clientId']];
      if (match != null) used.add(match.id);
      restored.add(SpeedPoint.fromServer(json, local: match));
    }
    // Not uploaded yet (e.g. offline): keep, still to upload.
    for (final p in local) {
      if (!used.contains(p.id) && p.remoteId == null) {
        restored.add(p.copyWith(dirty: true));
      }
    }
    await host.setMyPoints(restored);

    final settings = await api.getSettings();
    if (settings != null) {
      await host.restoreSettings(host.settings.restoredFrom(settings));
      _settingsDirty = false;
    } else {
      _settingsDirty = true;
    }
  }

  /// Signs this phone out. Your points stay in your account and are removed
  /// from this phone. Throws if some changes couldn't be uploaded yet.
  Future<void> signOut() async {
    await syncNow(pull: false);
    if (pending > 0) {
      throw const ApiException(
        0,
        'offline',
        'Some changes are not backed up yet. Connect to the internet and try again.',
      );
    }
    try {
      await api.logout();
    } on ApiException {
      // Already signed out on the server: fine.
    }
    _setSignedOut();
    _signedOutEmail = null;
    await host.setMyPoints([]);
    await _save();
    notifyListeners();
    await syncNow();
  }

  /// Deletes the account on the server. Points stay on this phone only.
  Future<void> deleteAccount() async {
    await api.deleteAccount();
    _setSignedOut();
    _signedOutEmail = null;
    _pendingDeletes.clear();
    await host.setMyPoints([
      for (final p in host.myPoints)
        p.copyWith(remoteId: () => null, dirty: false),
    ]);
    await _save();
    notifyListeners();
    await syncNow();
  }

  // ---- Community actions (need a connection) ----

  /// "Still there" / "Gone" (null takes the vote back). Returns the updated
  /// point, or null if it is now hidden from the map.
  Future<SpeedPoint?> vote(SpeedPoint point, String? vote) async {
    await _ensureAccount();
    final id = point.remoteId!;
    final res = vote == null ? await api.unvote(id) : await api.vote(id, vote);
    final json = res['point'] as Map<String, dynamic>;
    final visible = json['status'] == 'active';
    final updated = SpeedPoint.fromServer(json, local: point);
    await host.setCommunity([
      for (final c in host.communityPoints)
        if (c.remoteId != id) c else if (visible) updated,
    ]);
    return visible ? updated : null;
  }

  Future<void> report(SpeedPoint point, String reason, String? comment) async {
    await _ensureAccount();
    await api.report(point.remoteId!, reason, comment);
  }
}
