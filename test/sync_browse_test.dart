// Cameras and bumps show wherever the user looks on the map, not only
// around the driver (SyncService.browse). Uses a fake server.
import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/models/app_settings.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/services/api_client.dart';
import 'package:new_project/services/storage.dart';
import 'package:new_project/services/sync_service.dart';
import 'package:new_project/utils/geo.dart';

const duhok = (lat: 36.8669, lng: 42.9569);
const erbil = (lat: 36.1911, lng: 44.0092);
const baghdad = (lat: 33.3152, lng: 44.3661);

Map<String, dynamic> serverPoint(String id, ({double lat, double lng}) at) => {
  'id': id,
  'type': 'camera',
  'lat': at.lat,
  'lng': at.lng,
  'speedLimit': 80,
  'direction': null,
  'note': null,
  'visibility': 'public',
  'status': 'active',
  'confirmCount': 0,
  'goneCount': 0,
  'lastConfirmedAt': null,
  'mine': false,
  'myVote': null,
  'createdAt': '2026-11-10T00:00:00.000Z',
  'updatedAt': '2026-11-10T00:00:00.000Z',
};

/// A server holding [points]; answers "points near a place" like the real one.
class FakeApi extends ApiClient {
  FakeApi() : super(baseUrl: 'http://fake');

  final Map<String, Map<String, dynamic>> points = {};
  final List<({double lat, double lng, double radiusKm})> asked = [];

  @override
  Future<Map<String, dynamic>> nearby(
    double lat,
    double lng,
    double radiusKm, {
    String? since,
  }) async {
    asked.add((lat: lat, lng: lng, radiusKm: radiusKm));
    return {
      'points': [
        for (final p in points.values)
          if (distanceMeters(lat, lng, p['lat'] as double, p['lng'] as double) <=
              radiusKm * 1000)
            p,
      ],
      'removed': <String>[],
      'serverTime': DateTime.now().toUtc().toIso8601String(),
      'truncated': false,
    };
  }
}

class _MemoryStorage extends Storage {
  @override
  Future<void> savePoints(List<SpeedPoint> points) async {}
  @override
  Future<void> saveSettings(AppSettings s) async {}
  @override
  Future<void> saveCommunity(List<SpeedPoint> points) async {}
  // Already signed in (anonymous), so no account is created.
  @override
  Future<Map<String, dynamic>?> loadSyncState() async => {'token': 't'};
  @override
  Future<void> saveSyncState(Map<String, dynamic> state) async {}
}

/// A phone in Duhok.
class Phone implements SyncHost {
  Phone(this.api) {
    sync = SyncService(api: api, storage: _MemoryStorage(), host: this);
  }

  final FakeApi api;
  late SyncService sync;
  ({double lat, double lng}) at = duhok;

  @override
  List<SpeedPoint> myPoints = [];
  @override
  List<SpeedPoint> communityPoints = [];
  @override
  AppSettings settings = const AppSettings();
  @override
  ({double lat, double lng})? get syncPosition => at;
  @override
  Future<void> setMyPoints(List<SpeedPoint> points) async => myPoints = points;
  @override
  Future<void> setCommunity(List<SpeedPoint> points) async =>
      communityPoints = points;
  @override
  Future<void> restoreSettings(AppSettings s) async => settings = s;

  Set<String?> get seen => {for (final p in communityPoints) p.remoteId};
}

void main() {
  late FakeApi api;
  late Phone phone;

  setUp(() async {
    api = FakeApi()
      ..points['d1'] = serverPoint('d1', duhok)
      ..points['e1'] = serverPoint('e1', erbil)
      ..points['b1'] = serverPoint('b1', baghdad);
    phone = Phone(api);
    await phone.sync.start();
    await phone.sync.syncNow();
  });

  tearDown(() => phone.sync.dispose());

  test('at first only the driver\'s area is loaded', () {
    expect(phone.seen, {'d1'});
  });

  test('looking at Erbil on the map loads Erbil, and keeps Duhok', () async {
    await phone.sync.browse(erbil.lat, erbil.lng, 5);
    expect(phone.seen, {'d1', 'e1'});
    // At least the normal area size, so moving around the city needs one
    // download.
    expect(api.asked.last.radiusKm, SyncService.areaRadiusKm);
  });

  test('a place already loaded is not downloaded again', () async {
    await phone.sync.browse(erbil.lat, erbil.lng, 5);
    final calls = api.asked.length;
    await phone.sync.browse(erbil.lat + 0.01, erbil.lng, 5);
    await phone.sync.browse(duhok.lat, duhok.lng, 5); // the driver's area
    expect(api.asked.length, calls);
  });

  test('a wide view loads up to the server limit (100 km)', () async {
    await phone.sync.browse(baghdad.lat, baghdad.lng, 400);
    expect(api.asked.last.radiusKm, SyncService.maxBrowseRadiusKm);
    expect(phone.seen, contains('b1'));
  });

  test('a camera removed in Erbil disappears when Erbil is loaded again', () async {
    await phone.sync.browse(erbil.lat, erbil.lng, 5);
    api.points.remove('e1');
    // Later (another phone session): Erbil is loaded again.
    final again = Phone(api);
    again.communityPoints = phone.communityPoints;
    await again.sync.start();
    await again.sync.syncNow();
    await again.sync.browse(erbil.lat, erbil.lng, 5);
    expect(again.seen, {'d1'});
    again.sync.dispose();
  });

  test('the driver\'s full refresh keeps places loaded elsewhere', () async {
    await phone.sync.browse(erbil.lat, erbil.lng, 5);
    // Driving 20 km away makes the driver's area download again in full.
    phone.at = (lat: duhok.lat + 0.18, lng: duhok.lng);
    await phone.sync.syncNow();
    expect(phone.seen, contains('e1'));
  });
}
