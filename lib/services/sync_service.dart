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
  static const retryAfterFailure = Duration(minutes: 2);
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
  int _settingsVersion = 0;

  // Runtime state
  bool _started = false;
  bool _syncing = false;
  bool _again = false;
  String? _error;
  DateTime? _lastFailure;
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
      host.myPoints.where((p) => p.dirty).length +
      _pendingDeletes.length +
      (_settingsDirty ? 1 : 0);

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

  /// Undo of a delete: true if it hadn't reached the server yet.
  bool cancelDelete(String remoteId) {
    final was = _pendingDeletes.remove(remoteId);
    if (was && _started) unawaited(_save());
    return was;
  }

  /// A point with this server id was deleted on the phone.
  void queueDelete(String remoteId) {
    _pendingDeletes.add(remoteId);
    if (_started) unawaited(_save());
    localChange();
  }

  void settingsChanged() {
    _settingsDirty = true;
    _settingsVersion++;
    if (!_started) return;
    unawaited(_save());
    localChange();
  }

  /// The driver moved: download a new area when far from the last one.
  /// After a failed sync it waits [retryAfterFailure] (GPS updates every
  /// second, and a server that's down shouldn't be asked every second).
  void positionChanged(double lat, double lng) {
    if (!_started || _syncing || _lock != null) return;
    final failed = _lastFailure;
    if (failed != null &&
        DateTime.now().difference(failed) < retryAfterFailure) {
      return;
    }
    final cLat = _centerLat;
    final cLng = _centerLng;
    if (cLat == null ||
        cLng == null ||
        distanceMeters(cLat, cLng, lat, lng) > refetchDistanceM) {
      unawaited(syncNow());
    }
  }

  // ---- Sync ----

  Future<void>? _lock;

  /// Runs [fn] when nothing else is syncing or changing the account, so a
  /// background sync can never mix two accounts' data.
  Future<T> _locked<T>(Future<T> Function() fn) async {
    while (_lock != null) {
      await _lock;
    }
    final done = Completer<void>();
    _lock = done.future;
    try {
      return await fn();
    } finally {
      _lock = null;
      done.complete();
    }
  }

  /// Uploads local changes, then (with [pull]) downloads the community map.
  /// If a sync is already running, waits for it and then runs again (so
  /// changes made meanwhile are included). Returns false when it couldn't
  /// finish (see [error]).
  Future<bool> syncNow({bool pull = true}) async {
    if (!_started) return false;
    return _locked(() => _run(pull));
  }

  Future<bool> _run(bool pull) async {
    _syncing = true;
    notifyListeners();
    var ok = false;
    try {
      await _ensureAccount();
      if (_token != null) {
        await _pushDeletes();
        // A point the server refused doesn't stop the rest of the sync.
        final problem = await _pushPoints();
        await _pushSettings();
        if (pull) await _pull();
        _lastSyncAt = DateTime.now();
        _error = problem;
        ok = problem == null;
      } else if (_signedOutEmail != null) {
        _error =
            'You were signed out. Sign in again to back up and update the map.';
      }
    } on ApiException catch (e) {
      await _onError(e);
    } catch (e) {
      debugPrint('Sync failed: $e');
      _error = 'Sync failed. It will try again.';
    } finally {
      _syncing = false;
      _lastFailure = ok ? null : DateTime.now();
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
        _error =
            'You were signed out. Sign in again to back up and update the map.';
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

  /// Uploads changed points. Returns a message when the server refused
  /// some (they stay on this phone), or null.
  Future<String?> _pushPoints() async {
    String? problem;
    for (final sent in host.myPoints.where((p) => p.dirty).toList()) {
      final remoteId = sent.remoteId;
      try {
        if (remoteId == null) {
          final res = await api.createPoint({
            ...sent.toServerJson(),
            'clientId': sent.id,
          });
          await _applyCreated(sent, res);
        } else {
          await api.updatePoint(remoteId, sent.toServerJson());
          await _updateMine(
            sent.id,
            (now) => now.copyWith(dirty: !_sameOnServer(now, sent)),
          );
        }
      } on ApiException catch (e) {
        // No connection, signed out, banned, server down: stop for now.
        if (e.offline ||
            e.status == 401 ||
            e.code == 'banned' ||
            e.status >= 500) {
          rethrow;
        }
        if (e.status == 429) {
          problem = e.message; // daily limit: the rest goes up later
          break;
        }
        if (remoteId != null && e.status == 404) {
          // Removed by a moderator: keep it on this phone only.
          await _updateMine(
            sent.id,
            (now) => now.copyWith(remoteId: () => null, dirty: false),
          );
        } else if (remoteId != null && e.status == 403) {
          // Now owned by the community (deleted on my other phone, kept by
          // drivers who confirmed it).
          await _toCommunity(sent.id);
        } else {
          // Refused (e.g. other drivers confirmed it, so it can't be made
          // private). Keep it here; the server's copy comes back on the
          // next download.
          await _updateMine(sent.id, (now) => now.copyWith(dirty: false));
          problem = 'A point could not be saved online: ${e.message}';
        }
      }
    }
    return problem;
  }

  /// Moves my point [id] to the community points (keeping its sound).
  Future<void> _toCommunity(String id) async {
    final p = host.myPoints.where((x) => x.id == id).firstOrNull;
    if (p == null) return;
    await _updateMine(id, (_) => null);
    await host.setCommunity([
      for (final c in host.communityPoints)
        if (c.remoteId != p.remoteId) c,
      p.copyWith(community: true, dirty: false),
    ]);
  }

  Future<void> _applyCreated(SpeedPoint sent, Map<String, dynamic> res) async {
    final server = res['point'] as Map<String, dynamic>;
    final remoteId = server['id'] as String;
    final stillHere = host.myPoints.any((p) => p.id == sent.id);
    if (!stillHere) {
      // Deleted on the phone while uploading: delete this upload too, but
      // never another point of mine it was merged into.
      if (server['mine'] == true && res['merged'] != true) {
        queueDelete(remoteId);
      }
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
    // Compare with what the server has (a retried upload returns the first
    // version), so any difference is uploaded again.
    final onServer = SpeedPoint.fromServer(server);
    await _updateMine(
      sent.id,
      (now) => duplicate
          ? null // the same point twice on this phone
          : now.copyWith(
              remoteId: () => remoteId,
              dirty: !_sameOnServer(now, onServer),
            ),
    );
  }

  Future<void> _pushSettings() async {
    if (!_settingsDirty) return;
    final version = _settingsVersion;
    await api.putSettings(host.settings.toBackupJson());
    // Changed again while uploading: upload again next time.
    if (version == _settingsVersion) _settingsDirty = false;
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
    final mine = <String, SpeedPoint>{for (final p in host.myPoints) p.id: p};
    final mineByRemote = {
      for (final p in mine.values)
        if (p.remoteId != null) p.remoteId!: p.id,
    };
    var mineChanged = false;

    for (final json in points) {
      final id = json['id'] as String;
      final localId = mineByRemote[id];
      final local = localId == null ? null : mine[localId];
      if (json['mine'] == true) {
        if (_pendingDeletes.contains(id)) continue;
        if (local == null) {
          // Added on my other phone.
          final p = SpeedPoint.fromServer(json);
          mine[p.id] = p;
          mineChanged = true;
        } else if (!local.dirty) {
          mine[local.id] = SpeedPoint.fromServer(json, local: local);
          mineChanged = true;
        }
        community.remove(id);
      } else {
        if (local != null && !local.dirty) {
          // No longer mine (deleted on my other phone, kept by the
          // community): it becomes a community point here too.
          mine.remove(local.id);
          mineChanged = true;
        }
        community[id] = SpeedPoint.fromServer(
          json,
          local: oldCommunity[id] ?? local,
        );
      }
    }
    for (final id in removed) {
      community.remove(id);
      // Deleted on my other phone, or removed by a moderator.
      final localId = mineByRemote[id];
      final local = localId == null ? null : mine[localId];
      if (local != null && !local.dirty) {
        mine.remove(local.id);
        mineChanged = true;
      }
    }
    if (mineChanged) await host.setMyPoints(mine.values.toList());
    await host.setCommunity(community.values.toList());
  }

  // ---- Account ----

  /// Backs up this phone's account with email + password (keeps everything).
  Future<void> register(String email, String password) => _locked(() async {
    await _ensureAccount();
    _setAccount(await api.register(email.trim(), password, _deviceName));
    _settingsDirty = true;
    _settingsVersion++;
    await _save();
    notifyListeners();
    await _run(true);
  });

  /// Signs in to an existing account. What this phone added so far moves
  /// into that account; the account's points and settings come back here.
  Future<void> signIn(String email, String password) => _locked(() async {
    // Upload what's on this phone first, so the server can merge it.
    if (_signedOutEmail == null) await _run(false);
    _setAccount(await api.login(email.trim(), password, _deviceName));
    await _save();
    notifyListeners();
    await _restoreFromAccount();
    _cursor = null; // votes etc. are per account: download the area again
    await _run(true);
  });

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
      // Deleted on this phone while signed out: stays deleted.
      if (_pendingDeletes.contains(json['id'])) continue;
      if (match != null && match.dirty) {
        // Changed on this phone while signed out: this phone's version wins.
        restored.add(match.copyWith(remoteId: () => json['id'] as String));
      } else {
        restored.add(SpeedPoint.fromServer(json, local: match));
      }
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
  Future<void> signOut() => _locked(() async {
    await _run(false);
    if (pending > 0) {
      throw const ApiException(
        0,
        'offline',
        'Some changes are not backed up yet. Connect to the internet and try again.',
      );
    }
    try {
      await api.logout();
    } on ApiException catch (e) {
      // Already signed out on the server is fine; no connection is not.
      if (e.offline) rethrow;
    }
    _setSignedOut();
    _signedOutEmail = null;
    await host.setMyPoints([]);
    await host.setCommunity([]);
    await _save();
    notifyListeners();
    await _run(true);
  });

  /// Deletes the account on the server. Points stay on this phone only.
  /// The server keeps your public points for other drivers (without your
  /// name), so on this phone they become community points; the rest stays
  /// on this phone only.
  Future<void> deleteAccount() => _locked(() async {
    await api.deleteAccount();
    _setSignedOut();
    _signedOutEmail = null;
    _pendingDeletes.clear();
    final mine = <SpeedPoint>[];
    final given = <SpeedPoint>[];
    for (final p in host.myPoints) {
      if (p.remoteId != null && p.shared) {
        given.add(p.copyWith(community: true, dirty: false));
      } else {
        mine.add(p.copyWith(remoteId: () => null, dirty: false));
      }
    }
    final givenIds = {for (final g in given) g.remoteId};
    await host.setMyPoints(mine);
    await host.setCommunity([
      for (final c in host.communityPoints)
        if (!givenIds.contains(c.remoteId)) c,
      ...given,
    ]);
    await _save();
    notifyListeners();
    await _run(true);
  });

  // ---- Community actions (need a connection) ----

  /// "Still there" / "Gone" (null takes the vote back). Returns the updated
  /// point, or null if it is now hidden from the map.
  Future<SpeedPoint?> vote(SpeedPoint point, String? vote) =>
      _locked(() => _vote(point, vote));

  Future<SpeedPoint?> _vote(SpeedPoint point, String? vote) async {
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

  Future<void> report(SpeedPoint point, String reason, String? comment) =>
      _locked(() async {
        await _ensureAccount();
        await api.report(point.remoteId!, reason, comment);
      });
}
