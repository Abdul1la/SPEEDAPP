import 'dart:convert';
import 'dart:isolate';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/route_plan.dart';
import '../models/speed_point.dart';

/// Big lists (thousands of points) are read and written on a background
/// isolate, so the map doesn't stutter; small ones right away (starting an
/// isolate costs more than that).
Future<T> _offMain<T>(int size, T Function() work) =>
    size > _bigData ? Isolate.run(work) : Future.sync(work);

/// About 250 points, in characters of JSON.
const _bigData = 50000;

/// Saves points and settings on the phone.
class Storage {
  static const _pointsKey = 'points_v1';
  static const _settingsKey = 'settings_v1';

  late final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  Future<List<SpeedPoint>> loadPoints() async {
    final raw = await _prefs.getString(_pointsKey);
    if (raw == null) return [];
    try {
      return await _offMain(raw.length, () => parsePoints(raw));
    } on FormatException {
      return [];
    }
  }

  Future<void> savePoints(List<SpeedPoint> points) async => _prefs.setString(
    _pointsKey,
    await _offMain(points.length * 200, () => exportPoints(points)),
  );

  Future<AppSettings> loadSettings() async {
    final raw = await _prefs.getString(_settingsKey);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings s) =>
      _prefs.setString(_settingsKey, jsonEncode(s.toJson()));

  // ---- Online ----

  static const _communityKey = 'community_v1';
  static const _syncKey = 'sync_v1';

  /// Points from other drivers, kept for offline use.
  Future<List<SpeedPoint>> loadCommunity() async {
    final raw = await _prefs.getString(_communityKey);
    if (raw == null) return [];
    try {
      return await _offMain(raw.length, () => _parseCommunity(raw));
    } catch (_) {
      return [];
    }
  }

  static List<SpeedPoint> _parseCommunity(String raw) => [
    for (final m in (jsonDecode(raw) as List).whereType<Map<String, dynamic>>())
      SpeedPoint.fromJson(m),
  ];

  Future<void> saveCommunity(List<SpeedPoint> points) async => _prefs.setString(
    _communityKey,
    await _offMain(
      points.length * 200,
      () => jsonEncode([for (final p in points) p.toJson()]),
    ),
  );

  static const _recentPlacesKey = 'recent_places_v1';

  /// Places picked in search lately, newest first.
  Future<List<Place>> loadRecentPlaces() async {
    final raw = await _prefs.getString(_recentPlacesKey);
    if (raw == null) return [];
    try {
      return [
        for (final m
            in (jsonDecode(raw) as List).whereType<Map<String, dynamic>>())
          Place.fromJson(m),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveRecentPlaces(List<Place> places) => _prefs.setString(
    _recentPlacesKey,
    jsonEncode([for (final p in places) p.toJson()]),
  );

  /// Sign-in token and sync progress (see SyncService).
  Future<Map<String, dynamic>?> loadSyncState() async {
    final raw = await _prefs.getString(_syncKey);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSyncState(Map<String, dynamic> state) =>
      _prefs.setString(_syncKey, jsonEncode(state));
}

String exportPoints(List<SpeedPoint> points) => const JsonEncoder.withIndent(
  ' ',
).convert(points.map((p) => p.toJson()).toList());

/// Reads points from text. Accepts:
///  * JSON: `[{"type":"camera","lat":33.31,"lng":44.36,"limit":80}, ...]`
///  * CSV lines: `lat,lng,type,limit,direction` (type/limit/direction optional)
///    e.g. `33.3152,44.3661,camera,80`
bool _validPlace(Object? lat, Object? lng) =>
    lat is num && lng is num && lat.abs() <= 90 && lng.abs() <= 180;

/// Drops values the app and server can't use (e.g. a limit of 2 km/h).
SpeedPoint _clean(SpeedPoint p) {
  final limit = p.speedLimit;
  final dir = p.direction;
  final note = p.note?.trim();
  return p.copyWith(
    speedLimit: () =>
        limit != null && limit >= 5 && limit <= 300 ? limit : null,
    direction: () => dir == null || !dir.isFinite ? null : dir % 360,
    note: () => note == null || note.isEmpty
        ? null
        : note.length > maxNoteLength
        ? note.substring(0, maxNoteLength)
        : note,
  );
}

List<SpeedPoint> parsePoints(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return [];
  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    final decoded = jsonDecode(trimmed);
    final list = decoded is List ? decoded : [decoded];
    return [
      for (final m in list.whereType<Map<String, dynamic>>())
        if (_validPlace(m['lat'], m['lng'] ?? m['lon'] ?? m['long']))
          _clean(SpeedPoint.fromJson(m)),
    ];
  }

  final out = <SpeedPoint>[];
  for (final line in const LineSplitter().convert(trimmed)) {
    final cells = line.split(RegExp(r'[,;\t]')).map((c) => c.trim()).toList();
    if (cells.length < 2) continue;
    final lat = double.tryParse(cells[0]);
    final lng = double.tryParse(cells[1]);
    if (lat == null || lng == null) continue; // header row or junk
    if (lat.abs() > 90 || lng.abs() > 180) continue;
    out.add(
      _clean(
        SpeedPoint(
          id: newPointId(),
          type: PointType.fromKey(
            cells.length > 2 ? cells[2].toLowerCase() : null,
          ),
          lat: lat,
          lng: lng,
          speedLimit: cells.length > 3 ? int.tryParse(cells[3]) : null,
          direction: cells.length > 4 ? double.tryParse(cells[4]) : null,
        ),
      ),
    );
  }
  if (out.isEmpty) {
    throw const FormatException('No points found in the text');
  }
  return out;
}
