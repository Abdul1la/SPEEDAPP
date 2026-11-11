import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/route_plan.dart';

/// The live server (used by release builds unless API_URL is set).
const liveApiUrl = 'https://speedapp-production.up.railway.app';

/// Where the backend runs. Set it when building:
///   flutter run --dart-define=API_URL=https://api.example.com
/// Without it: release builds use [liveApiUrl]; debug builds the computer
/// running the app (Android emulator: 10.0.2.2).
String defaultApiUrl() {
  const fromBuild = String.fromEnvironment('API_URL');
  if (fromBuild.isNotEmpty) return fromBuild;
  if (kReleaseMode) return liveApiUrl;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:3000';
  }
  return 'http://localhost:3000';
}

/// An error from the server (or no connection: [status] 0).
class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  bool get offline => status == 0;

  @override
  String toString() => message;
}

/// Thin typed wrapper around the Speed Alert API (see backend/README.md).
class ApiClient {
  ApiClient({String? baseUrl, http.Client? client})
    : baseUrl = baseUrl ?? defaultApiUrl(),
      _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  /// Sign-in token, sent with every request.
  String? token;

  static const _timeout = Duration(seconds: 15);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final request = http.Request(method, uri)
      ..headers['accept'] = 'application/json';
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _http.send(request).timeout(_timeout),
      ).timeout(_timeout);
    } on SocketException {
      throw const ApiException(0, 'offline', 'No internet connection.');
    } on TimeoutException {
      throw const ApiException(0, 'offline', 'The server is not answering.');
    } on http.ClientException {
      throw const ApiException(0, 'offline', 'No internet connection.');
    }
    Map<String, dynamic> json = const {};
    if (res.body.isNotEmpty) {
      try {
        json = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        json = const {};
      }
    }
    if (res.statusCode >= 400) {
      final error = json['error'] as Map<String, dynamic>?;
      throw ApiException(
        res.statusCode,
        error?['code'] as String? ?? 'error',
        error?['message'] as String? ??
            'Something went wrong (${res.statusCode}).',
      );
    }
    return json;
  }

  // ---- Sign in ----

  Future<Map<String, dynamic>> anonymous(String deviceName) =>
      _send('POST', '/v1/auth/anonymous', body: {'deviceName': deviceName});

  Future<Map<String, dynamic>> register(
    String email,
    String password,
    String deviceName,
  ) => _send(
    'POST',
    '/v1/auth/register',
    body: {'email': email, 'password': password, 'deviceName': deviceName},
  );

  Future<Map<String, dynamic>> login(
    String email,
    String password,
    String deviceName,
  ) => _send(
    'POST',
    '/v1/auth/login',
    body: {'email': email, 'password': password, 'deviceName': deviceName},
  );

  Future<void> logout() => _send('POST', '/v1/auth/logout');

  Future<void> deleteAccount() => _send('DELETE', '/v1/me');

  // ---- Points ----

  /// Points around a place; with [since], only changes.
  Future<Map<String, dynamic>> nearby(
    double lat,
    double lng,
    double radiusKm, {
    String? since,
  }) => _send(
    'GET',
    '/v1/points',
    query: {
      'lat': lat.toStringAsFixed(6),
      'lng': lng.toStringAsFixed(6),
      'radiusKm': radiusKm.toString(),
      'since': ?since,
    },
  );

  Future<Map<String, dynamic>> createPoint(Map<String, dynamic> body) =>
      _send('POST', '/v1/points', body: body);

  Future<Map<String, dynamic>> updatePoint(
    String id,
    Map<String, dynamic> body,
  ) => _send('PATCH', '/v1/points/$id', body: body);

  Future<Map<String, dynamic>> deletePoint(String id) =>
      _send('DELETE', '/v1/points/$id');

  Future<Map<String, dynamic>> vote(String id, String vote) =>
      _send('PUT', '/v1/points/$id/vote', body: {'vote': vote});

  Future<Map<String, dynamic>> unvote(String id) =>
      _send('DELETE', '/v1/points/$id/vote');

  /// The driver suddenly slowed down (a likely police radar). Returns
  /// `{ counted, radar }`; `radar` is the police radar found or kept there.
  Future<Map<String, dynamic>> slowdown(Map<String, dynamic> body) =>
      _send('POST', '/v1/slowdowns', body: body);

  Future<List<Map<String, dynamic>>> myPoints() async {
    final json = await _send('GET', '/v1/me/points');
    return (json['points'] as List).cast<Map<String, dynamic>>();
  }

  // ---- Settings backup ----

  Future<Map<String, dynamic>?> getSettings() async {
    final json = await _send('GET', '/v1/me/settings');
    return json['settings'] as Map<String, dynamic>?;
  }

  Future<void> putSettings(Map<String, dynamic> settings) =>
      _send('PUT', '/v1/me/settings', body: {'settings': settings});

  // ---- Search and directions ----

  /// Places matching [query] (search as you type), nearest to (lat, lng)
  /// first when given.
  Future<List<Place>> places(
    String query, {
    double? lat,
    double? lng,
    String? session,
  }) async {
    final json = await _send(
      'GET',
      '/v1/places',
      query: {
        'q': query,
        if (lat != null && lng != null) ...{
          'lat': lat.toStringAsFixed(5),
          'lng': lng.toStringAsFixed(5),
        },
        'session': ?session,
      },
    );
    return [
      for (final p in (json['places'] as List).cast<Map<String, dynamic>>())
        Place.fromJson(p),
    ];
  }

  /// Where a search result is (Google results come without their spot).
  Future<Place> place(String id, {String? session}) async {
    final json = await _send(
      'GET',
      '/v1/places/${Uri.encodeComponent(id)}',
      query: {'session': ?session},
    );
    return Place.fromJson(json['place'] as Map<String, dynamic>);
  }

  /// Driving routes, fastest first, with the cameras and bumps on each.
  Future<Map<String, dynamic>> routes(
    double fromLat,
    double fromLng,
    double toLat,
    double toLng,
  ) => _send(
    'GET',
    '/v1/routes',
    query: {
      'from': '${fromLat.toStringAsFixed(6)},${fromLng.toStringAsFixed(6)}',
      'to': '${toLat.toStringAsFixed(6)},${toLng.toStringAsFixed(6)}',
    },
  );
}
