import 'custom_sound.dart';

/// A place on the road the driver should be warned about.
enum PointType {
  camera('camera', 'Speed camera'),
  bump('bump', 'Speed bump');

  const PointType(this.key, this.label);

  /// Short stable id, used in saved data and in sound file names
  /// (e.g. `assets/sounds/camera_300.mp3`).
  final String key;
  final String label;

  static PointType fromKey(String? key) => PointType.values.firstWhere(
    (t) => t.key == key,
    orElse: () => PointType.camera,
  );
}

class SpeedPoint {
  const SpeedPoint({
    required this.id,
    required this.type,
    required this.lat,
    required this.lng,
    this.speedLimit,
    this.direction,
    this.note,
    this.sound,
    this.repeat,
    this.remoteId,
    this.shared = true,
    this.community = false,
    this.confirms = 0,
    this.gones = 0,
    this.myVote,
    this.dirty = false,
  });

  /// Builds a point from the server's JSON. [local] is this phone's copy, whose
  /// phone-only fields (id, sound, repeat) are kept.
  factory SpeedPoint.fromServer(
    Map<String, dynamic> json, {
    SpeedPoint? local,
  }) {
    final remoteId = json['id'] as String;
    final mine = json['mine'] == true;
    return SpeedPoint(
      id: local?.id ?? (json['clientId'] as String?) ?? 'c$remoteId',
      type: PointType.fromKey(json['type'] as String?),
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      speedLimit: (json['speedLimit'] as num?)?.round(),
      direction: (json['direction'] as num?)?.toDouble(),
      note: json['note'] as String?,
      sound: local?.sound,
      repeat: local?.repeat,
      remoteId: remoteId,
      shared: json['visibility'] != 'private',
      community: !mine,
      confirms: (json['confirmCount'] as num?)?.round() ?? 0,
      gones: (json['goneCount'] as num?)?.round() ?? 0,
      myVote: json['myVote'] as String?,
    );
  }

  final String id;
  final PointType type;
  final double lat;
  final double lng;

  /// Speed limit in km/h, or null if unknown / not relevant.
  final int? speedLimit;

  /// Travel direction (compass degrees, 0 = north) this point applies to.
  /// Null means it applies to both directions.
  final double? direction;

  final String? note;

  /// This point's own warning sound. Null uses the sound from Settings.
  final CustomSound? sound;

  /// How many times this point's warning plays. Null uses Settings.
  final int? repeat;

  // ---- Online (see SyncService) ----

  /// The point's id on the server, once uploaded / downloaded.
  final String? remoteId;

  /// Shown to other drivers (public). False = private, only synced to your
  /// own phones.
  final bool shared;

  /// Added by another driver (downloaded from the community map). Only its
  /// sound and repeat can be changed on this phone.
  final bool community;

  /// How many drivers said "still there" / "gone".
  final int confirms;
  final int gones;

  /// Your vote on a community point: "confirm", "gone" or null.
  final String? myVote;

  /// Changed on this phone and not uploaded yet.
  final bool dirty;

  SpeedPoint copyWith({
    PointType? type,
    double? lat,
    double? lng,
    int? Function()? speedLimit,
    double? Function()? direction,
    String? Function()? note,
    CustomSound? Function()? sound,
    int? Function()? repeat,
    String? Function()? remoteId,
    bool? shared,
    bool? community,
    int? confirms,
    int? gones,
    String? Function()? myVote,
    bool? dirty,
  }) {
    return SpeedPoint(
      id: id,
      type: type ?? this.type,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      speedLimit: speedLimit != null ? speedLimit() : this.speedLimit,
      direction: direction != null ? direction() : this.direction,
      note: note != null ? note() : this.note,
      sound: sound != null ? sound() : this.sound,
      repeat: repeat != null ? repeat() : this.repeat,
      remoteId: remoteId != null ? remoteId() : this.remoteId,
      shared: shared ?? this.shared,
      community: community ?? this.community,
      confirms: confirms ?? this.confirms,
      gones: gones ?? this.gones,
      myVote: myVote != null ? myVote() : this.myVote,
      dirty: dirty ?? this.dirty,
    );
  }

  SpeedPoint withId(String newId) => SpeedPoint(
    id: newId,
    type: type,
    lat: lat,
    lng: lng,
    speedLimit: speedLimit,
    direction: direction,
    note: note,
    sound: sound,
    repeat: repeat,
    remoteId: remoteId,
    shared: shared,
    community: community,
    confirms: confirms,
    gones: gones,
    myVote: myVote,
    dirty: dirty,
  );

  /// A copy that belongs to this phone only (for imported lists): no server
  /// id, and marked for upload.
  SpeedPoint asNewLocal(String newId) => SpeedPoint(
    id: newId,
    type: type,
    lat: lat,
    lng: lng,
    speedLimit: speedLimit,
    direction: direction,
    note: note,
    sound: sound,
    repeat: repeat,
    shared: shared,
    dirty: true,
  );

  /// The fields the server stores (for uploading).
  /// The fields the server stores, in the form it stores them (whole
  /// degrees, a valid limit, a note of at most 200 characters), so the
  /// server never refuses a point and copies compare equal.
  Map<String, dynamic> toServerJson() {
    final limit = speedLimit;
    final dir = direction;
    final text = note?.trim();
    return {
      'type': type.key,
      'lat': double.parse(lat.clamp(-90.0, 90.0).toStringAsFixed(6)),
      'lng': double.parse(lng.clamp(-180.0, 180.0).toStringAsFixed(6)),
      'speedLimit': limit != null && limit >= 5 && limit <= 300 ? limit : null,
      'direction': dir == null || !dir.isFinite ? null : dir.round() % 360,
      'note': text == null || text.isEmpty
          ? null
          : text.length > maxNoteLength
          ? text.substring(0, maxNoteLength)
          : text,
      'visibility': shared ? 'public' : 'private',
    };
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.key,
    'lat': lat,
    'lng': lng,
    if (speedLimit != null) 'limit': speedLimit,
    if (direction != null) 'dir': direction,
    if (note != null && note!.isNotEmpty) 'note': note,
    if (sound != null) 'sound': sound!.toJson(),
    if (repeat != null) 'repeat': repeat,
    if (remoteId != null) 'rid': remoteId,
    if (!shared) 'shared': false,
    if (community) 'community': true,
    if (confirms > 0) 'ok': confirms,
    if (gones > 0) 'gone': gones,
    if (myVote != null) 'vote': myVote,
    if (dirty) 'dirty': true,
  };

  factory SpeedPoint.fromJson(Map<String, dynamic> json, {String? fallbackId}) {
    final lat = (json['lat'] as num?)?.toDouble();
    final lng = (json['lng'] ?? json['lon'] ?? json['long']) as num?;
    if (lat == null || lng == null) {
      throw const FormatException('Point is missing lat/lng');
    }
    return SpeedPoint(
      id: (json['id'] as String?) ?? fallbackId ?? newPointId(),
      type: PointType.fromKey(json['type'] as String?),
      lat: lat,
      lng: lng.toDouble(),
      speedLimit: (json['limit'] as num?)?.round(),
      direction: (json['dir'] as num?)?.toDouble(),
      note: json['note'] as String?,
      sound: CustomSound.fromJson(json['sound']),
      repeat: (json['repeat'] as num?)?.round().clamp(1, maxRepeat),
      remoteId: json['rid'] as String?,
      shared: json['shared'] != false,
      community: json['community'] == true,
      confirms: (json['ok'] as num?)?.round() ?? 0,
      gones: (json['gone'] as num?)?.round() ?? 0,
      myVote: json['vote'] as String?,
      dirty: json['dirty'] == true,
    );
  }
}

/// Longest note the server keeps.
const int maxNoteLength = 200;

int _idCounter = 0;

String newPointId() {
  _idCounter++;
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_idCounter.toRadixString(36)}';
}
