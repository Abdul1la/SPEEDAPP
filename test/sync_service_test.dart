// End-to-end sync test against a real backend. Skipped unless
// SPEEDALERT_TEST_API is set, e.g.:
//
//   cd backend && docker compose up -d db
//   PORT=3100 RATE_LIMIT=false \
//     DATABASE_URL=mysql://speedalert:speedalert@127.0.0.1:3306/speedalert_test \
//     node src/server.ts &
//   SPEEDALERT_TEST_API=http://localhost:3100 flutter test test/sync_service_test.dart
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:new_project/models/app_settings.dart';
import 'package:new_project/models/speed_point.dart';
import 'package:new_project/services/api_client.dart';
import 'package:new_project/services/storage.dart';
import 'package:new_project/services/sync_service.dart';

final apiUrl = Platform.environment['SPEEDALERT_TEST_API'];

/// Storage kept in memory.
class _MemoryStorage extends Storage {
  Map<String, dynamic>? sync;
  @override
  Future<void> savePoints(List<SpeedPoint> points) async {}
  @override
  Future<void> saveSettings(AppSettings s) async {}
  @override
  Future<void> saveCommunity(List<SpeedPoint> points) async {}
  @override
  Future<Map<String, dynamic>?> loadSyncState() async => sync;
  @override
  Future<void> saveSyncState(Map<String, dynamic> state) async => sync = state;
}

/// One phone: its points, settings and position.
class Phone implements SyncHost {
  Phone(this.lat, this.lng) {
    sync = SyncService(
      api: ApiClient(baseUrl: apiUrl),
      storage: _MemoryStorage(),
      host: this,
    );
  }

  late SyncService sync;
  double lat;
  double lng;
  @override
  List<SpeedPoint> myPoints = [];
  @override
  List<SpeedPoint> communityPoints = [];
  @override
  AppSettings settings = const AppSettings();

  @override
  ({double lat, double lng})? get syncPosition => (lat: lat, lng: lng);
  @override
  Future<void> setMyPoints(List<SpeedPoint> points) async => myPoints = points;
  @override
  Future<void> setCommunity(List<SpeedPoint> points) async =>
      communityPoints = points;
  @override
  Future<void> restoreSettings(AppSettings s) async => settings = s;

  Future<void> start() async {
    await sync.start();
    await sync.syncNow(); // wait for the first sync (start() doesn't)
  }

  void add(SpeedPoint p) => myPoints = [...myPoints, p.copyWith(dirty: true)];
}

// A random place for each run, so runs don't see each other's points.
final _rnd = Random();
final base = (
  lat: 20 + _rnd.nextDouble() * 20,
  lng: 20 + _rnd.nextDouble() * 20,
);
double _north(double meters) => base.lat + meters / 111320;

SpeedPoint camera(String id, {double meters = 0, bool shared = true}) =>
    SpeedPoint(
      id: id,
      type: PointType.camera,
      lat: _north(meters),
      lng: base.lng,
      speedLimit: 80,
      shared: shared,
    );

void main() {
  final skip = apiUrl == null
      ? 'Set SPEEDALERT_TEST_API to run against a backend'
      : null;

  test('a point added on one phone reaches another', () async {
    final a = Phone(base.lat, base.lng);
    final b = Phone(base.lat, base.lng);
    await a.start();
    await b.start();

    a.add(camera('a1'));
    expect(await a.sync.syncNow(), isTrue);
    final uploaded = a.myPoints.single;
    expect(uploaded.remoteId, isNotNull);
    expect(uploaded.dirty, isFalse);

    expect(await b.sync.syncNow(), isTrue);
    final seen = b.communityPoints.singleWhere(
      (p) => p.remoteId == uploaded.remoteId,
    );
    expect(seen.community, isTrue);
    expect(seen.speedLimit, 80);
  }, skip: skip);

  test('private points stay private; edits and deletes reach others', () async {
    final a = Phone(base.lat, base.lng);
    final b = Phone(base.lat, base.lng);
    await a.start();
    await b.start();

    a.add(camera('pub', meters: 300));
    a.add(camera('priv', meters: 600, shared: false));
    await a.sync.syncNow();
    await b.sync.syncNow();
    final pubId = a.myPoints.firstWhere((p) => p.id == 'pub').remoteId;
    expect(b.communityPoints.map((p) => p.remoteId), contains(pubId));
    expect(
      b.communityPoints.where(
        (p) => p.speedLimit == 80 && p.lat == _north(600),
      ),
      isEmpty,
    );

    // Edit, then delete.
    a.myPoints = [
      for (final p in a.myPoints)
        p.id == 'pub' ? p.copyWith(speedLimit: () => 60, dirty: true) : p,
    ];
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect(
      b.communityPoints.firstWhere((p) => p.remoteId == pubId).speedLimit,
      60,
    );

    a.myPoints = a.myPoints.where((p) => p.id != 'pub').toList();
    a.sync.queueDelete(pubId!);
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect(b.communityPoints.map((p) => p.remoteId), isNot(contains(pubId)));
  }, skip: skip);

  test(
    'adding a camera that is already on the map turns it into the community point',
    () async {
      final a = Phone(base.lat, base.lng);
      final b = Phone(base.lat, base.lng);
      await a.start();
      await b.start();
      a.add(camera('first', meters: 1000));
      await a.sync.syncNow();
      final remoteId = a.myPoints.single.remoteId;

      b.add(camera('again', meters: 1005));
      await b.sync.syncNow();
      expect(b.myPoints, isEmpty);
      final merged = b.communityPoints.singleWhere(
        (p) => p.remoteId == remoteId,
      );
      expect(merged.myVote, 'confirm');
      expect(merged.confirms, 1);
    },
    skip: skip,
  );

  test(
    'votes: "gone" from three drivers takes a point off every map',
    () async {
      final owner = Phone(base.lat, base.lng);
      await owner.start();
      owner.add(camera('doomed', meters: 2000));
      await owner.sync.syncNow();
      final remoteId = owner.myPoints.single.remoteId;

      final voters = [for (var i = 0; i < 3; i++) Phone(base.lat, base.lng)];
      SpeedPoint? last;
      for (final v in voters) {
        await v.start();
        final p = v.communityPoints.singleWhere((c) => c.remoteId == remoteId);
        last = await v.sync.vote(p, 'gone');
      }
      expect(last, isNull); // hidden after the third vote
      expect(
        voters.last.communityPoints.map((p) => p.remoteId),
        isNot(contains(remoteId)),
      );
    },
    skip: skip,
  );

  test(
    'backup: sign in on a new phone brings back points and settings',
    () async {
      final email = 'sync${DateTime.now().microsecondsSinceEpoch}@example.com';
      final old = Phone(base.lat, base.lng);
      await old.start();
      old.add(camera('mine', meters: 3000));
      old.add(camera('secret', meters: 3500, shared: false));
      old.settings = old.settings
          .copyWith(cameraDistances: [400, 150])
          .withRepeat('camera', 3);
      old.sync.settingsChanged();
      await old.sync.register(email, 'correct horse');
      expect(old.sync.account?.email, email);
      expect(old.sync.pending, 0);

      final fresh = Phone(base.lat, base.lng);
      await fresh.start();
      fresh.add(camera('new-phone', meters: 4000));
      await fresh.sync.signIn(email, 'correct horse');
      expect(fresh.sync.account?.email, email);
      expect(fresh.myPoints.map((p) => p.id).toSet(), {
        'mine',
        'secret',
        'new-phone',
      });
      expect(fresh.settings.cameraDistances, [400, 150]);
      expect(fresh.settings.repeatFor('camera'), 3);

      // Signing out removes the account's points from this phone.
      await fresh.sync.signOut();
      expect(fresh.myPoints, isEmpty);
      expect(fresh.sync.account?.isAnonymous, isTrue);
    },
    skip: skip,
  );

  test(
    'a point the server refuses does not stop the rest of the sync',
    () async {
      final owner = Phone(base.lat, base.lng);
      final other = Phone(base.lat, base.lng);
      await owner.start();
      await other.start();
      owner.add(camera('confirmed', meters: 5000));
      await owner.sync.syncNow();
      final remoteId = owner.myPoints.single.remoteId!;
      await other.sync.syncNow();
      await other.sync.vote(
        other.communityPoints.singleWhere((p) => p.remoteId == remoteId),
        'confirm',
      );

      // Others confirmed it, so the server refuses making it private...
      owner.myPoints = [
        owner.myPoints.single.copyWith(shared: false, dirty: true),
      ];
      // ...but a second change in the same sync still goes up.
      owner.add(camera('second', meters: 5600));
      await owner.sync.syncNow();
      expect(owner.sync.error, contains('could not be saved online'));
      expect(
        owner.myPoints.firstWhere((p) => p.id == 'second').remoteId,
        isNotNull,
      );
      expect(owner.sync.pending, 0);
    },
    skip: skip,
  );

  test('a point deleted on my other phone disappears here too', () async {
    final email = 'two${DateTime.now().microsecondsSinceEpoch}@example.com';
    final a = Phone(base.lat, base.lng);
    await a.start();
    a.add(camera('shared-acct', meters: 6000, shared: false));
    await a.sync.register(email, 'correct horse');

    final b = Phone(base.lat, base.lng);
    await b.start();
    await b.sync.signIn(email, 'correct horse');
    expect(b.myPoints.map((p) => p.id), ['shared-acct']);

    final remoteId = a.myPoints.single.remoteId!;
    a.myPoints = [];
    a.sync.queueDelete(remoteId);
    await a.sync.syncNow();
    await b.sync.syncNow();
    expect(b.myPoints, isEmpty);
  }, skip: skip);

  test('offline: changes wait, nothing is lost', () async {
    final phone = Phone(base.lat, base.lng);
    phone.sync = SyncService(
      api: ApiClient(baseUrl: 'http://127.0.0.1:9'), // nothing listens here
      storage: _MemoryStorage(),
      host: phone,
    );
    await phone.sync.start();
    phone.add(camera('offline'));
    expect(await phone.sync.syncNow(), isFalse);
    expect(phone.sync.error, contains('Offline'));
    expect(phone.myPoints.single.dirty, isTrue);
    expect(phone.sync.pending, 1);
    phone.sync.dispose();
  });
}
