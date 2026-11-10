import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/speed_point.dart';
import '../utils/geo.dart';
import 'alert_engine.dart';

enum LocationStatus { ok, serviceOff, denied, deniedForever }

class LocationService {
  Future<LocationStatus> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationStatus.serviceOff;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return switch (perm) {
      LocationPermission.denied => LocationStatus.denied,
      LocationPermission.deniedForever => LocationStatus.deniedForever,
      _ => LocationStatus.ok,
    };
  }

  Future<DriveSample?> lastKnown() async {
    try {
      final p = await Geolocator.getLastKnownPosition();
      return p == null ? null : _toSample(p);
    } catch (_) {
      return null;
    }
  }

  /// Live GPS, about once per second. Keeps running when the app is in the
  /// background (Android shows a notification, iOS shows the blue pill).
  Stream<DriveSample> gps() {
    final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Speed camera warnings are on',
          notificationText: 'Watching the road for cameras and speed bumps',
          notificationChannelName: 'Driving warnings',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    } else {
      settings = const LocationSettings(accuracy: LocationAccuracy.best);
    }
    return Geolocator.getPositionStream(
      locationSettings: settings,
    ).map(_toSample);
  }

  Future<void> openSettings() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
  }

  static DriveSample _toSample(Position p) => DriveSample(
    lat: p.latitude,
    lng: p.longitude,
    speedMps: p.speed.isFinite && p.speed > 0 ? p.speed : 0,
    heading: p.heading.isFinite && p.heading >= 0 ? p.heading : null,
    time: p.timestamp,
  );
}

/// A pretend drive past [point], one reading per second. Used by the
/// "Test drive" button so warnings can be tried at home.
Stream<DriveSample> simulateDrive(
  SpeedPoint point, {
  required double kmh,
  double startBefore = 700,
  double endAfter = 250,
}) async* {
  final travel = point.direction ?? 0;
  final (sLat, sLng) = destinationPoint(
    point.lat,
    point.lng,
    travel + 180,
    startBefore,
  );
  final step = kmh / 3.6;
  for (double m = 0; m <= startBefore + endAfter; m += step) {
    final (lat, lng) = destinationPoint(sLat, sLng, travel, m);
    yield DriveSample(
      lat: lat,
      lng: lng,
      speedMps: step,
      heading: travel,
      time: DateTime.now(),
    );
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}
