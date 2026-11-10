import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../app_controller.dart';
import '../map/map_styles.dart';
import '../map/marker_icons.dart';
import '../models/speed_point.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import '../utils/geo.dart';
import '../widgets/hud.dart';
import '../widgets/point_editor.dart';
import '../widgets/ui.dart';
import 'settings_screen.dart';

/// Main screen: a full-screen map with floating frosted controls.
///
/// Layout (top to bottom):
///  * status chip (only when GPS is searching or during a test drive)
///  * warning pill (only when a camera / bump is ahead)
///  * map controls capsule: settings, mute, follow me
///  * round speedometer (bottom left)
///  * bottom bar: what's next on your road · Add
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.app});

  final AppController app;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // Where the map starts before the first GPS fix.
  static const _fallbackCamera = CameraPosition(
    target: LatLng(30, 30),
    zoom: 3,
  );

  /// Bottom bar and speedometer sizes (used to keep things clear of them).
  static const _barHeight = 72.0;
  static const _gaugeSize = 92.0;
  static const _panelHeight = _barHeight + Space.md + _gaugeSize;

  GoogleMapController? _map;

  /// The middle of the map (where "Map center" puts a new point).
  LatLng? _mapCenter;
  final MarkerIcons _icons = MarkerIcons();
  bool _follow = true;
  bool _drawingIcons = false;
  bool _hintDismissed = false;
  Object? _lastFollowed;
  double _bearing = 0;
  late final AppLifecycleListener _lifecycle;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_onAppChanged);
    // Coming back from the phone settings: try GPS again.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (app.locationStatus != LocationStatus.ok) app.startGps();
      },
    );
  }

  @override
  void dispose() {
    app.removeListener(_onAppChanged);
    _lifecycle.dispose();
    super.dispose();
  }

  void _onAppChanged() {
    final pos = app.position;
    if (!_follow || pos == null || identical(pos, _lastFollowed)) return;
    _lastFollowed = pos;
    _moveCameraTo(pos.lat, pos.lng, pos.speedKmh);
  }

  void _moveCameraTo(double lat, double lng, double kmh) {
    final map = _map;
    if (map == null) return;
    final moving = kmh > 8;
    if (moving && app.course != null) _bearing = app.course!;
    map.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(lat, lng),
          zoom: kmh > 80 ? 15.5 : 16.5,
          bearing: _bearing,
          tilt: moving ? 45 : 0,
        ),
      ),
    );
  }

  void _recenter() {
    setState(() => _follow = true);
    final pos = app.position;
    if (pos != null) _moveCameraTo(pos.lat, pos.lng, pos.speedKmh);
  }

  Future<void> _prepareIcons() async {
    if (_drawingIcons) return;
    _drawingIcons = true;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final changed = await _icons.prepare(app.mapPoints, dpr);
    _drawingIcons = false;
    if (changed && mounted) setState(() {});
  }

  void _toast(String message, {SnackBarAction? action}) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: action,
          margin: EdgeInsets.fromLTRB(
            Space.md,
            0,
            Space.md,
            bottom + _panelHeight + Space.xl,
          ),
        ),
      );
  }

  void _openSettings() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => SettingsScreen(app: app)),
  );

  // ---- Adding & editing points ----------------------------------------

  Future<void> _openEditor({
    SpeedPoint? existing,
    LatLng? at,
    PointPlace place = PointPlace.mapSpot,
    bool fromLongPress = true,
  }) async {
    final pos = app.position;
    final result = await showPointEditor(
      context,
      app,
      existing: existing,
      lat: at?.latitude,
      lng: at?.longitude,
      myLocation: pos == null ? null : (lat: pos.lat, lng: pos.lng),
      place: place,
      fromLongPress: fromLongPress,
      myCourse: app.course,
    );
    if (!mounted || result == null) return;
    switch (result.action) {
      case PointSheetAction.testDrive:
        final kmh = app.startSimulation(result.point);
        setState(() => _follow = true);
        _toast('Test drive at ${kmh.round()} km/h — listen for the warnings');
      case PointSheetAction.saved:
        _toast('${result.point.type.label} saved');
        if (existing == null) _showOnMap(result.point);
      case PointSheetAction.deleted:
        _toast('${result.point.type.label} deleted');
    }
  }

  /// Zooms the map to a new point so the driver sees where it went.
  void _showOnMap(SpeedPoint pt) {
    final pos = app.position;
    final nearMe =
        pos != null && distanceMeters(pos.lat, pos.lng, pt.lat, pt.lng) < 50;
    // At my location the map keeps following me; elsewhere it stays on the pin.
    if (!nearMe && _follow) setState(() => _follow = false);
    _map?.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(pt.lat, pt.lng), 17.5),
    );
  }

  /// Saves a point dragged to a new place, with Undo.
  Future<void> _movePoint(SpeedPoint before, LatLng to) async {
    await app.updatePoint(before.copyWith(lat: to.latitude, lng: to.longitude));
    if (!mounted) return;
    _toast(
      '${before.type.label} moved',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          // Put back only the place, keeping any edits made since.
          final now = app.points.where((q) => q.id == before.id).firstOrNull;
          if (now == null) return;
          app.updatePoint(now.copyWith(lat: before.lat, lng: before.lng));
        },
      ),
    );
  }

  /// Add button: the full form, placed at the current GPS position (or the
  /// middle of the map while waiting for GPS).
  Future<void> _openAdd() async {
    if (app.isSimulating) {
      _toast('Stop the test drive first');
      return;
    }
    final pos = app.position;
    final center =
        _mapCenter ??
        (pos != null ? LatLng(pos.lat, pos.lng) : _fallbackCamera.target);
    await _openEditor(
      at: center,
      place: PointPlace.myLocation,
      fromLongPress: false,
    );
  }

  // ---- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: ListenableBuilder(
          listenable: app,
          builder: (context, _) {
            if (!_icons.hasAll(app.mapPoints)) _prepareIcons();
            return Stack(children: [_buildMap(), _buildTop(), _buildBottom()]);
          },
        ),
      ),
    );
  }

  Widget _buildMap() {
    final insets = MediaQuery.paddingOf(context);
    final p = context.palette;
    final pos = app.position;
    final active = app.active;
    final locationOk = app.locationStatus == LocationStatus.ok;

    final markers = <Marker>{
      // My points and other drivers' points.
      for (final pt in app.mapPoints)
        Marker(
          markerId: MarkerId(pt.id),
          position: LatLng(pt.lat, pt.lng),
          icon: _icons.iconFor(pt),
          anchor: MarkerIcons.pinAnchor,
          consumeTapEvents: true,
          onTap: () => _openEditor(existing: pt),
          // Hold and drag a pin to move it (only my own points).
          draggable: !app.isSimulating && !pt.community,
          onDragEnd: (to) => _movePoint(pt, to),
        ),
      if (app.isSimulating && pos != null && _icons.car != null)
        Marker(
          markerId: const MarkerId('_car'),
          position: LatLng(pos.lat, pos.lng),
          icon: _icons.car!,
          flat: true,
          rotation: pos.heading ?? 0,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 10,
        ),
    };

    final circles = <Circle>{
      if (active != null)
        Circle(
          circleId: const CircleId('zone'),
          center: LatLng(active.point.lat, active.point.lng),
          radius: app.settings.distancesFor(active.point.type).first.toDouble(),
          fillColor: p.colorFor(active.point.type).withValues(alpha: 0.06),
          strokeColor: p.colorFor(active.point.type).withValues(alpha: 0.7),
          strokeWidth: 2,
        ),
    };

    return Listener(
      // Dragging the map stops "follow me" until the user taps it again.
      onPointerMove: (_) {
        if (_follow) setState(() => _follow = false);
      },
      child: GoogleMap(
        initialCameraPosition: pos != null
            ? CameraPosition(target: LatLng(pos.lat, pos.lng), zoom: 16)
            : _fallbackCamera,
        style: mapStyleFor(app.settings.mapLook, Theme.of(context).brightness),
        myLocationEnabled: locationOk && !app.isSimulating,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        mapToolbarEnabled: false,
        compassEnabled: false,
        buildingsEnabled: false,
        markers: markers,
        circles: circles,
        // Keep the car low on the screen to see more road ahead, and keep
        // the Google logo visible above the drive panel.
        padding: EdgeInsets.only(
          top: insets.top + 150,
          bottom: insets.bottom + _panelHeight + Space.xl,
        ),
        onMapCreated: (c) {
          _map = c;
          final pt = app.position;
          if (pt != null) _moveCameraTo(pt.lat, pt.lng, pt.speedKmh);
        },
        onCameraMove: (camera) => _mapCenter = camera.target,
        onLongPress: (latLng) => _openEditor(at: latLng),
      ),
    );
  }

  Widget _buildTop() {
    final p = context.palette;
    final active = app.active;

    final Widget card;
    if (active != null) {
      card = WarningBanner(
        key: ValueKey('alert-${active.point.id}'),
        alert: active,
        zone: app.settings.distancesFor(active.point.type).first,
      );
    } else if (app.ready && app.locationStatus != LocationStatus.ok) {
      card = _LocationProblem(key: const ValueKey('loc'), app: app);
    } else if (app.ready && app.mapPoints.isEmpty && !_hintDismissed) {
      card = _NoticeCard(
        key: const ValueKey('hint'),
        icon: Icons.add_location_alt_outlined,
        color: p.primary,
        title: 'Add your first point',
        text: 'Tap Add to put one at your location, or long-press the map.',
        action: IconButton(
          onPressed: () => setState(() => _hintDismissed = true),
          tooltip: 'Dismiss',
          icon: Icon(Icons.close_rounded, color: p.textTertiary, size: 20),
        ),
      );
    } else {
      card = const SizedBox(key: ValueKey('none'), width: double.infinity);
    }

    final Widget? status = app.isSimulating
        ? StatusChip(
            color: p.primary,
            label: 'Test drive',
            onTap: app.stopSimulation,
            trailing: Text(
              'Stop',
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          )
        : app.locationStatus == LocationStatus.ok && app.position == null
        ? StatusChip(color: p.warning, label: 'Finding GPS…')
        : null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (status != null) ...[
              Align(alignment: Alignment.centerLeft, child: status),
              const SizedBox(height: Space.sm),
            ],
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              // Grows out from the top, like the Dynamic Island.
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(
                  alignment: Alignment.topCenter,
                  scale: Tween(begin: 0.85, end: 1.0).animate(anim),
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, ?current],
              ),
              child: card,
            ),
            const SizedBox(height: Space.md),
            Align(
              alignment: Alignment.centerRight,
              child: MapControlGroup(
                controls: [
                  MapControl(
                    icon: Icons.settings_outlined,
                    tooltip: 'Settings',
                    onTap: _openSettings,
                  ),
                  MapControl(
                    icon: app.settings.muted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_outlined,
                    tooltip: app.settings.muted ? 'Unmute' : 'Mute',
                    active: app.settings.muted,
                    activeColor: p.danger,
                    onTap: app.toggleMute,
                  ),
                  MapControl(
                    icon: _follow
                        ? Icons.navigation_rounded
                        : Icons.navigation_outlined,
                    tooltip: _follow ? 'Following you' : 'Follow me',
                    active: _follow,
                    onTap: _recenter,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottom() {
    final p = context.palette;
    final pos = app.position;
    final active = app.active;
    return Positioned(
      left: Space.md,
      right: Space.md,
      bottom: 0,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: Space.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SpeedGauge(
              kmh: pos?.speedKmh ?? 0,
              limit: active?.point.speedLimit,
              overLimit: active?.overLimit ?? false,
              size: _gaugeSize,
            ),
            const SizedBox(height: Space.md),
            Frosted(
              radius: _barHeight / 2,
              padding: const EdgeInsets.all(10),
              child: SizedBox(
                height: _barHeight - 20,
                child: Row(
                  children: [
                    Expanded(child: _DriveInfo(app: app)),
                    const SizedBox(width: Space.sm),
                    Semantics(
                      button: true,
                      label: 'Add a camera or speed bump at your location',
                      child: Material(
                        color: p.primary,
                        shape: const StadiumBorder(),
                        child: InkWell(
                          customBorder: const StadiumBorder(),
                          onTap: _openAdd,
                          child: Container(
                            height: _barHeight - 20,
                            padding: const EdgeInsets.symmetric(horizontal: 22),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.add_rounded,
                                  color: p.onPrimary,
                                  size: 22,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Add',
                                  style: TextStyle(
                                    color: p.onPrimary,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Left part of the bottom bar: the one most useful thing to know now.
class _DriveInfo extends StatelessWidget {
  const _DriveInfo({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final active = app.active;
    final next = app.next;
    final kmh = app.position?.speedKmh ?? 0;

    final String title;
    final String sub;
    final Color badge;
    final Widget icon;
    var titleIsNumber = false;

    if (active != null && active.point.speedLimit != null) {
      final limit = active.point.speedLimit!;
      final over = active.overLimit;
      title = over
          ? '${(kmh - limit).round()} km/h too fast'
          : 'Keep under $limit';
      sub = '${active.point.type.label} ahead';
      badge = over ? p.danger : p.success;
      icon = const Icon(Icons.speed_rounded, color: Colors.white, size: 22);
    } else if (active != null) {
      title = '${active.point.type.label} ahead';
      sub = 'Reduce your speed';
      badge = p.colorFor(active.point.type);
      icon = PointGlyph(
        type: active.point.type,
        size: 22,
        color: p.onColorFor(active.point.type),
      );
    } else if (next != null) {
      title = formatDistance(next.distance);
      titleIsNumber = true;
      sub = next.point.speedLimit != null
          ? 'Next ${next.point.type.label.toLowerCase()} · '
                '${next.point.speedLimit} km/h'
          : 'Next ${next.point.type.label.toLowerCase()}';
      badge = p.colorFor(next.point.type);
      icon = PointGlyph(
        type: next.point.type,
        size: 22,
        color: p.onColorFor(next.point.type),
      );
    } else if (app.position == null) {
      title = 'Finding GPS…';
      sub = 'Make sure location is on';
      badge = p.warning;
      icon = const Icon(
        Icons.gps_not_fixed_rounded,
        color: Colors.white,
        size: 22,
      );
    } else {
      title = 'All clear';
      sub = app.mapPoints.isEmpty
          ? 'No points saved yet'
          : 'Nothing within 10 km';
      badge = p.success;
      icon = const Icon(Icons.check_rounded, color: Colors.white, size: 24);
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: Row(
        key: ValueKey('$title|$sub'.replaceAll(RegExp(r'[0-9.]'), '')),
        children: [
          PointBadge(color: badge, size: 46, child: icon),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleIsNumber
                      ? numberStyle(21, color: p.text, weight: FontWeight.w800)
                      : TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: p.text,
                        ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Frosted(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(
        Space.md,
        Space.md,
        Space.sm,
        Space.md,
      ),
      child: Row(
        children: [
          PointBadge(
            color: color,
            size: 44,
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: p.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: TextStyle(color: p.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _LocationProblem extends StatelessWidget {
  const _LocationProblem({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (title, text, button, onPressed) = switch (app.locationStatus) {
      LocationStatus.serviceOff => (
        'Location is off',
        'Turn it on to get warnings.',
        'Turn on',
        app.openLocationSettings,
      ),
      LocationStatus.deniedForever => (
        'Location blocked',
        'Allow location for this app in Settings.',
        'Settings',
        app.openLocationSettings,
      ),
      _ => (
        'Location needed',
        'Allow location so the app can warn you.',
        'Allow',
        app.startGps,
      ),
    };
    return _NoticeCard(
      icon: Icons.location_off_outlined,
      color: p.danger,
      title: title,
      text: text,
      action: Padding(
        padding: const EdgeInsets.only(left: Space.xs, right: Space.xs),
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          ),
          child: Text(button),
        ),
      ),
    );
  }
}
