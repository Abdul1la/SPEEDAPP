import 'dart:async';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../app_controller.dart';
import '../map/map_styles.dart';
import '../map/car_turn.dart';
import '../map/marker_icons.dart';
import '../map/visible_pins.dart';
import '../models/app_settings.dart';
import '../models/route_plan.dart';
import '../models/speed_point.dart';
import '../services/alert_engine.dart' show DriveSample;
import '../services/api_client.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import '../utils/geo.dart';
import '../widgets/hud.dart';
import '../widgets/point_editor.dart';
import '../widgets/route_sheet.dart';
import '../widgets/ui.dart';
import 'search_screen.dart';
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

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
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
  Offset? _pointerDown;
  final MarkerIcons _icons = MarkerIcons();
  bool _follow = true;
  bool _drawingIcons = false;
  bool _hintDismissed = false;
  Object? _lastFollowed;
  double _bearing = 0;
  late final AppLifecycleListener _lifecycle;

  /// The car's angle on the map as shown now. It turns smoothly to each new
  /// driving direction (see [CarTurn]), ahead of the map's own turn. Only
  /// the map is redrawn while it turns, not the panels.
  final ValueNotifier<double?> _carAngle = ValueNotifier(null);
  CarTurn? _turn;
  late final AnimationController _carTurn =
      AnimationController(vsync: this, duration: CarTurn.duration)
        ..addListener(() {
          final turn = _turn;
          if (turn != null) _carAngle.value = turn.at(_carTurn.value);
        });

  /// The part of the map on screen (known once the camera stops), so only
  /// the pins there and near the car are drawn.
  final ValueNotifier<LatLngBounds?> _view = ValueNotifier(null);

  /// Changes when new pin icons are ready.
  final ValueNotifier<int> _iconsVersion = ValueNotifier(0);

  /// Everything the map is drawn from; the panels only follow [app].
  late final Listenable _mapInputs = Listenable.merge([
    app,
    _carAngle,
    _view,
    _iconsVersion,
  ]);

  // Pins chosen for the screen, made again only when their inputs change.
  List<SpeedPoint>? _pinsFrom;
  LatLngBounds? _pinsView;
  (int, int)? _pinsCarCell;
  List<SpeedPoint> _pins = const [];

  /// One marker per point, kept while the point, its icon and the test
  /// drive mode stay the same (so the map isn't sent unchanged pins).
  final Map<String, (SpeedPoint, BitmapDescriptor, bool, Marker)> _markers = {};
  List<SpeedPoint>? _iconsCheckedFor;

  /// Choosing a route: the sheet covers the bottom half of the map.
  bool _planning = false;

  /// Showing the whole remaining route (and me on it), kept up to date.
  bool _overview = false;
  DateTime _lastOverviewFit = DateTime(2000);
  bool _loadingRoute = false;
  StreamSubscription<String>? _messages;

  /// Route lines as map coordinates (made once per route, not every frame).
  final Map<RouteOption, List<LatLng>> _lines = Map.identity();

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_onAppChanged);
    _messages = app.messages.listen((m) {
      if (mounted) _toast(m);
    });
    // Coming back from the phone settings: try GPS again.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        // Only check again: the permission prompt itself pauses and resumes
        // the app, and asking again at once would be a loop on Android.
        if (app.locationStatus != LocationStatus.ok) app.startGps(ask: false);
      },
    );
  }

  @override
  void dispose() {
    _messages?.cancel();
    app.removeListener(_onAppChanged);
    _lifecycle.dispose();
    _carTurn.dispose();
    _carAngle.dispose();
    _view.dispose();
    _iconsVersion.dispose();
    super.dispose();
  }

  /// Turns the car to [angle] smoothly, the short way round.
  void _turnCarTo(double? angle) {
    if (angle == null) return;
    final shown = _carAngle.value;
    if (shown == null) {
      _carAngle.value = angle; // first fix: no turn
      return;
    }
    final aim = _turn != null && _carTurn.isAnimating ? _turn!.to : shown;
    if (shortestTurn(aim, angle).abs() < 0.5) return; // already there
    _turn = CarTurn(shown, angle);
    _carTurn.forward(from: 0);
  }

  void _onAppChanged() {
    final pos = app.position;
    _turnCarTo(app.course ?? pos?.heading);
    if (_overview) {
      if (!app.routeActive) {
        // Route ended (arrived): back to following the car.
        _overview = false;
        _recenter();
      } else if (DateTime.now().difference(_lastOverviewFit).inSeconds >= 5) {
        _fitRemainingRoute();
      }
      return;
    }
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
      // Slower than the car's own turn (CarTurn.duration), so the car turns
      // first and the map follows: a left turn looks left.
      duration: const Duration(milliseconds: 1000),
    );
  }

  void _recenter() {
    setState(() {
      _follow = true;
      _overview = false;
    });
    final pos = app.position;
    if (pos != null) _moveCameraTo(pos.lat, pos.lng, pos.speedKmh);
  }

  /// The camera stopped: remember what is on screen (for the pins), and if
  /// the user moved the map somewhere, load the cameras and bumps there
  /// (another city, for example). While the map follows the car, the
  /// driver's own area is already loaded.
  Future<void> _loadVisibleArea() async {
    final map = _map;
    if (map == null) return;
    try {
      final b = await map.getVisibleRegion();
      if (!mounted) return;
      _view.value = b;
      if (_follow) return;
      final lat = (b.northeast.latitude + b.southwest.latitude) / 2;
      final lng = (b.northeast.longitude + b.southwest.longitude) / 2;
      final km =
          distanceMeters(
            lat,
            lng,
            b.northeast.latitude,
            b.northeast.longitude,
          ) /
          1000;
      unawaited(app.sync.browse(lat, lng, km));
    } catch (_) {
      // The map was closed meanwhile.
    }
  }

  Future<void> _prepareIcons() async {
    if (_drawingIcons) return;
    _drawingIcons = true;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final changed = await _icons.prepare(app.mapPoints, dpr);
    _drawingIcons = false;
    if (changed && mounted) _iconsVersion.value++;
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
    // Only a real GPS fix counts as "my location" (not a saved old one).
    final pos = app.livePosition;
    // A new point at my location while driving warns only in my direction;
    // otherwise (parked, a spot on the map) it starts as "both ways".
    final driving = (pos?.speedKmh ?? 0) > 10 && app.course != null;
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
      presetDirection: driving && place == PointPlace.myLocation,
    );
    if (!mounted || result == null) return;
    switch (result.action) {
      case PointSheetAction.testDrive:
        final kmh = app.startSimulation(result.point);
        setState(() => _follow = true);
        final saved = existing == null
            ? '${result.point.type.label} saved. '
            : '';
        _toast(
          app.settings.muted
              ? '${saved}Test drive at ${kmh.round()} km/h. Sound is muted: unmute to hear the warnings'
              : '${saved}Test drive at ${kmh.round()} km/h. Listen for the warnings',
        );
      case PointSheetAction.saved:
        _toast('${result.point.type.label} saved');
        if (existing == null) _showOnMap(result.point);
      case PointSheetAction.deleted:
        _toast(
          '${result.point.type.label} deleted',
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => app.restorePoint(result.point),
          ),
        );
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
    _mapCenter = center;
    await _openEditor(
      at: center,
      place: PointPlace.myLocation,
      fromLongPress: false,
    );
  }

  // ---- Search and directions -------------------------------------------

  Future<void> _openSearch() async {
    final place = await showPlaceSearch(context, app);
    if (place == null || !mounted) return;
    await _planTo(place);
  }

  /// Gets the ways to drive to [place], lets the driver pick one, starts it.
  Future<void> _planTo(Place place) async {
    if (app.isSimulating) app.stopSimulation();
    setState(() {
      _loadingRoute = true;
      _follow = false;
    });
    try {
      await app.planRoute(place);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _loadingRoute = false);
        _toast(
          e.offline
              ? 'No internet connection. Directions need internet.'
              : e.message,
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _loadingRoute = false;
      _planning = true;
    });
    // After the map padding for the sheet is applied.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitRoutes());
    final start = await showRouteOptions(context, app);
    if (!mounted) return;
    setState(() => _planning = false);
    if (start) {
      app.startRoute();
      _recenter();
    } else {
      app.endRoute();
      _recenter();
    }
  }

  /// Shows every route option (and where I am) on the map.
  void _fitRoutes() {
    final map = _map;
    if (map == null || app.routeOptions.isEmpty) return;
    var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
    void include(double lat, double lng) {
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    }

    for (final r in app.routeOptions) {
      for (final pt in r.path) {
        include(pt.lat, pt.lng);
      }
    }
    final pos = app.position;
    if (pos != null) include(pos.lat, pos.lng);
    map.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        48,
      ),
    );
  }

  Future<void> _reroute() async {
    try {
      await app.reroute();
      _toast('New route');
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  /// Live overview: the rest of the route and where I am, updated as I
  /// drive (every few seconds). Follow-me (the arrow button) ends it.
  void _showOverview() {
    setState(() {
      _overview = true;
      _follow = false;
    });
    _fitRemainingRoute();
  }

  void _fitRemainingRoute() {
    final map = _map;
    final r = app.route;
    if (map == null || r == null) return;
    _lastOverviewFit = DateTime.now();
    var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
    void include(double lat, double lng) {
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    }

    final from = app.routeIndex.clamp(0, r.path.length - 1);
    for (var i = from; i < r.path.length; i++) {
      include(r.path[i].lat, r.path[i].lng);
    }
    final pos = app.position;
    if (pos != null) include(pos.lat, pos.lng);
    map.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        56,
      ),
    );
  }

  List<LatLng> _lineFor(RouteOption r) =>
      _lines[r] ??= [for (final pt in r.path) LatLng(pt.lat, pt.lng)];

  // ---- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Status bar icons sit on the map: light icons only on a dark map.
    final brightness = Theme.of(context).brightness;
    final darkMap = switch (app.settings.mapLook) {
      MapLook.dark => true,
      MapLook.auto => brightness == Brightness.dark,
      MapLook.light || MapLook.standard => false,
    };
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkMap ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        // Three parts redrawn on their own: the map (also for each frame of
        // the car turning), and the top and bottom panels (on app changes).
        body: Stack(
          children: [
            ListenableBuilder(
              listenable: _mapInputs,
              builder: (context, _) => _buildMap(),
            ),
            ListenableBuilder(
              listenable: app,
              builder: (context, _) => RepaintBoundary(child: _buildTop()),
            ),
            ListenableBuilder(
              listenable: app,
              builder: (context, _) => _buildBottom(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    final insets = MediaQuery.paddingOf(context);
    final p = context.palette;
    final pos = app.position;
    final active = app.active;

    final all = app.mapPoints;
    if (!identical(all, _iconsCheckedFor)) {
      _iconsCheckedFor = all;
      final ids = {for (final p in all) p.id};
      _markers.removeWhere((id, _) => !ids.contains(id));
      if (!_icons.hasAll(all)) _prepareIcons();
    }
    final markers = <Marker>{
      // My points and other drivers' points: those on screen and nearby.
      for (final pt in _visiblePins(all, pos)) _markerFor(pt),
      // My car (instead of the blue dot). It lies flat on the map, pointing
      // where I'm driving; faded until the GPS has a live fix.
      if (pos != null && _icons.car != null)
        Marker(
          markerId: const MarkerId('_car'),
          position: LatLng(pos.lat, pos.lng),
          icon: _icons.car!,
          flat: true,
          rotation: _carAngle.value ?? app.course ?? pos.heading ?? 0,
          anchor: const Offset(0.5, 0.5),
          alpha: app.isSimulating || app.livePosition != null ? 1 : 0.55,
          zIndexInt: 10,
          consumeTapEvents: true,
          onTap: _recenter,
        ),
    };

    final polylines = _routeLines(p);
    final dest = app.destination;
    if (dest != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('_destination'),
          position: LatLng(dest.lat, dest.lng),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
          infoWindow: InfoWindow(title: dest.name, snippet: dest.address),
          zIndexInt: 5,
        ),
      );
    }

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
      // Dragging the map stops "follow me" until the user taps it again;
      // the small wobble of tapping a pin doesn't.
      onPointerDown: (e) => _pointerDown = e.position,
      onPointerUp: (_) => _pointerDown = null,
      onPointerMove: (e) {
        final start = _pointerDown;
        if (start == null || (e.position - start).distance < kTouchSlop) return;
        if (_follow || _overview) {
          setState(() {
            _follow = false;
            _overview = false;
          });
        }
      },
      child: GoogleMap(
        initialCameraPosition: pos != null
            ? CameraPosition(target: LatLng(pos.lat, pos.lng), zoom: 16)
            : _fallbackCamera,
        style: mapStyleFor(app.settings.mapLook, Theme.of(context).brightness),
        // The car marker shows where I am (not Google's blue dot).
        myLocationEnabled: false,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        mapToolbarEnabled: false,
        compassEnabled: false,
        buildingsEnabled: false,
        markers: markers,
        circles: circles,
        polylines: polylines,
        // Keep the car low on the screen to see more road ahead, and keep
        // the Google logo visible above the drive panel.
        padding: EdgeInsets.only(
          top: insets.top + 150,
          // While choosing a route the sheet covers the lower half.
          bottom: _planning
              ? MediaQuery.sizeOf(context).height * routeSheetHeight
              : insets.bottom + _panelHeight + Space.xl,
        ),
        onMapCreated: (c) {
          _map = c;
          final pt = app.position;
          if (pt != null) _moveCameraTo(pt.lat, pt.lng, pt.speedKmh);
        },
        onCameraMove: (camera) => _mapCenter = camera.target,
        onCameraIdle: _loadVisibleArea,
        onLongPress: (latLng) => _openEditor(at: latLng),
      ),
    );
  }

  // Route lines, made again only when the routes or the chosen one change.
  List<RouteOption>? _linesOf;
  bool? _linesActive;
  int? _linesSelected;
  Palette? _linesPalette;
  Set<Polyline> _polylines = const {};

  Set<Polyline> _routeLines(Palette p) {
    final options = app.routeOptions;
    if (identical(options, _linesOf) &&
        app.routeActive == _linesActive &&
        app.selectedRoute == _linesSelected &&
        identical(p, _linesPalette)) {
      return _polylines;
    }
    _linesOf = options;
    _linesActive = app.routeActive;
    _linesSelected = app.selectedRoute;
    _linesPalette = p;
    _lines.removeWhere((r, _) => !options.contains(r));
    return _polylines = <Polyline>{
      for (var i = 0; i < options.length; i++)
        if (!app.routeActive || i == app.selectedRoute)
          Polyline(
            polylineId: PolylineId('route$i'),
            points: _lineFor(options[i]),
            color: i == app.selectedRoute
                ? p.primary
                : p.textTertiary.withValues(alpha: 0.8),
            width: i == app.selectedRoute ? 7 : 5,
            zIndex: i == app.selectedRoute ? 2 : 1,
            consumeTapEvents: true,
            onTap: () => app.selectRoute(i),
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
    };
  }

  /// The pins to draw now (see [pinsToShow]). Chosen again only when the
  /// points, the screen, or the car's square kilometer change.
  List<SpeedPoint> _visiblePins(List<SpeedPoint> all, DriveSample? pos) {
    final view = _view.value;
    final cell = pos == null
        ? null
        : ((pos.lat * 100).round(), (pos.lng * 100).round());
    if (identical(all, _pinsFrom) &&
        view == _pinsView &&
        cell == _pinsCarCell) {
      return _pins;
    }
    _pinsFrom = all;
    _pinsView = view;
    _pinsCarCell = cell;
    return _pins = pinsToShow(
      all,
      view: view,
      carLat: pos?.lat,
      carLng: pos?.lng,
    );
  }

  Marker _markerFor(SpeedPoint pt) {
    final icon = _icons.iconFor(pt);
    final sim = app.isSimulating;
    final kept = _markers[pt.id];
    if (kept != null &&
        identical(kept.$1, pt) &&
        identical(kept.$2, icon) &&
        kept.$3 == sim) {
      return kept.$4;
    }
    final marker = Marker(
      markerId: MarkerId(pt.id),
      position: LatLng(pt.lat, pt.lng),
      icon: icon,
      anchor: MarkerIcons.pinAnchor,
      consumeTapEvents: true,
      onTap: () => _openEditor(existing: pt),
      // Hold and drag a pin to move it (only my own points).
      draggable: !sim && !pt.community,
      onDragEnd: (to) => _movePoint(pt, to),
    );
    _markers[pt.id] = (pt, icon, sim, marker);
    return marker;
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
    } else if (app.askStillThere case final radar?) {
      // Just drove past a police radar: one tap keeps the map accurate.
      card = StillThereCard(
        key: ValueKey('still-${radar.id}'),
        point: radar,
        onAnswer: app.answerStillThere,
        onClose: app.dismissStillThere,
      );
    } else if (app.ready &&
        app.locationStatus != null &&
        app.locationStatus != LocationStatus.ok) {
      card = _LocationProblem(key: const ValueKey('loc'), app: app);
    } else if (_loadingRoute) {
      card = _NoticeCard(
        key: const ValueKey('routing'),
        icon: Icons.alt_route_rounded,
        color: p.primary,
        title: 'Finding the ways…',
        text: 'Looking for routes and the cameras on them.',
      );
    } else if (app.routeActive && app.destination != null) {
      card = _RouteBanner(
        key: const ValueKey('route'),
        app: app,
        onEnd: app.endRoute,
        onReroute: _reroute,
      );
    } else if (_planning) {
      card = const SizedBox(key: ValueKey('planning'), width: double.infinity);
    } else if (app.ready && app.mapPoints.isEmpty && !_hintDismissed) {
      card = Column(
        key: const ValueKey('hint'),
        children: [
          _SearchBar(onTap: _openSearch),
          const SizedBox(height: Space.sm),
          _NoticeCard(
            icon: Icons.add_location_alt_outlined,
            color: p.primary,
            title: 'Add your first point',
            text: 'Tap Add to put one at your location, or long-press the map.',
            action: IconButton(
              onPressed: () => setState(() => _hintDismissed = true),
              tooltip: 'Dismiss',
              icon: Icon(Icons.close_rounded, color: p.textTertiary, size: 20),
            ),
          ),
        ],
      );
    } else {
      // Nothing to warn about: search for a place to drive to.
      card = _SearchBar(key: const ValueKey('search'), onTap: _openSearch);
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
        : app.locationStatus == LocationStatus.ok && app.livePosition == null
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
                  // Always here, even when a warning covers the search bar.
                  MapControl(
                    icon: Icons.search_rounded,
                    tooltip: 'Search places',
                    onTap: _openSearch,
                  ),
                  if (app.routeActive)
                    MapControl(
                      icon: Icons.alt_route_rounded,
                      tooltip: 'See the whole route',
                      active: _overview,
                      onTap: _overview ? _recenter : _showOverview,
                    ),
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
              // Live speed only (an old saved position has an old speed).
              kmh: (app.isSimulating ? pos : app.livePosition)?.speedKmh ?? 0,
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

/// "Search places" pill at the top of the map.
class _SearchBar extends StatelessWidget {
  const _SearchBar({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      label: 'Search places',
      child: GestureDetector(
        onTap: onTap,
        child: Frosted(
          radius: 26,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: 14,
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded, color: p.textSecondary),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  'Search places, e.g. Duhok',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, color: p.textSecondary),
                ),
              ),
              Icon(Icons.alt_route_rounded, color: p.primary, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

/// While driving a route: where to, how far, when I'll arrive.
class _RouteBanner extends StatelessWidget {
  const _RouteBanner({
    super.key,
    required this.app,
    required this.onEnd,
    required this.onReroute,
  });

  final AppController app;
  final VoidCallback onEnd;
  final VoidCallback onReroute;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dest = app.destination!;
    final left = app.remainingM;
    final secs = app.remainingS;
    final String sub;
    if (app.offRoute) {
      sub = 'You left the route';
    } else if (left == null || secs == null) {
      sub = dest.address;
    } else {
      final arrive = DateTime.now().add(Duration(seconds: secs));
      final hh = arrive.hour.toString().padLeft(2, '0');
      final mm = arrive.minute.toString().padLeft(2, '0');
      sub =
          '${formatDistance(left)} · ${formatDuration(secs)} · arrive $hh:$mm';
    }
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
            color: app.offRoute ? p.warning : p.primary,
            size: 44,
            child: const Icon(
              Icons.flag_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dest.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: app.offRoute ? p.warning : p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (app.offRoute)
            TextButton(onPressed: onReroute, child: const Text('New route')),
          IconButton(
            tooltip: 'End route',
            onPressed: onEnd,
            icon: Icon(Icons.close_rounded, color: p.textTertiary, size: 20),
          ),
        ],
      ),
    );
  }
}
