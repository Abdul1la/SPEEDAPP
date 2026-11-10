import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/route_plan.dart';
import '../services/alert_engine.dart';
import '../theme/app_theme.dart';
import '../utils/geo.dart';
import '../widgets/hud.dart';
import '../widgets/route_sheet.dart';
import '../widgets/ui.dart';
import 'search_screen.dart';

/// Everything about one way to the destination: the place, the trip, every
/// camera and bump on the way (in order), and turn-by-turn directions.
/// Returns true when the driver taps Start.
Future<bool> showRouteDetails(
  BuildContext context,
  AppController app,
  int index,
) async {
  final start = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
      builder: (_) => RouteDetailsScreen(app: app, index: index),
    ),
  );
  return start ?? false;
}

class RouteDetailsScreen extends StatelessWidget {
  const RouteDetailsScreen({super.key, required this.app, required this.index});

  final AppController app;
  final int index;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dest = app.destination;
    final options = app.routeOptions;
    if (dest == null || index >= options.length) {
      return const Scaffold(
        body: Center(child: Text('This route is no longer available.')),
      );
    }
    final route = options[index];
    final stops = route.stopsFrom(app.mapPoints);

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'To ${dest.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xxl),
        children: [
          _PlaceCard(place: dest, from: app.position),
          const SectionLabel('The trip'),
          _TripCard(route: route, fastest: index == 0 && options.length > 1),
          SectionLabel(
            stops.isEmpty ? 'On the way' : 'On the way · ${stops.length}',
          ),
          if (stops.isEmpty)
            AppCard(
              padding: const EdgeInsets.all(Space.lg),
              child: Text(
                'No speed cameras or bumps known on this way. Drive carefully anyway.',
                style: TextStyle(fontSize: 14, color: p.textSecondary),
              ),
            )
          else
            AppCard(
              child: Column(
                children: [
                  for (var i = 0; i < stops.length; i++) ...[
                    if (i > 0) const Divider(indent: 60),
                    _StopRow(stop: stops[i], route: route),
                  ],
                ],
              ),
            ),
          if (route.steps.isNotEmpty) ...[
            SectionLabel('Directions · ${route.steps.length} steps'),
            AppCard(
              child: Column(
                children: [
                  for (var i = 0; i < route.steps.length; i++) ...[
                    if (i > 0) const Divider(indent: 60),
                    _StepRow(step: route.steps[i]),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          Space.lg,
          Space.sm,
          Space.lg,
          Space.lg,
        ),
        child: FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.navigation_rounded),
          label: const Text('Start this route'),
        ),
      ),
    );
  }
}

/// The destination: what it is, where, how far in a straight line.
class _PlaceCard extends StatelessWidget {
  const _PlaceCard({required this.place, this.from});
  final Place place;
  final DriveSample? from;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final f = from;
    final straight = f == null
        ? null
        : distanceMeters(f.lat, f.lng, place.lat, place.lng);
    return AppCard(
      padding: const EdgeInsets.all(Space.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(color: p.primary, size: 44, icon: placeIcon(place.kind)),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  place.name,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  placeKindLabel(place.kind),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: p.primary,
                  ),
                ),
                if (place.address.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    place.address,
                    style: TextStyle(fontSize: 14, color: p.textSecondary),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  [
                    if (straight != null)
                      '${formatDistance(straight)} from you in a straight line',
                    '${place.lat.toStringAsFixed(5)}, ${place.lng.toStringAsFixed(5)}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: p.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Time, distance, arrival, roads, and what's on the way in numbers.
class _TripCard extends StatelessWidget {
  const _TripCard({required this.route, required this.fastest});
  final RouteOption route;
  final bool fastest;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final arrive = DateTime.now().add(Duration(seconds: route.durationS));
    final hh = arrive.hour.toString().padLeft(2, '0');
    final mm = arrive.minute.toString().padLeft(2, '0');
    final avgKmh = route.durationS == 0
        ? 0
        : route.distanceM / route.durationS * 3.6;
    return AppCard(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: formatDuration(route.durationS),
                        style: numberStyle(28, color: p.text),
                      ),
                      TextSpan(
                        text: '  ${formatDistance(route.distanceM.toDouble())}',
                        style: TextStyle(fontSize: 16, color: p.textSecondary),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (fastest)
                Text(
                  'Fastest',
                  style: TextStyle(
                    color: p.success,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Text(
            'Arrive at about $hh:$mm · average ${avgKmh.round()} km/h',
            style: TextStyle(fontSize: 14, color: p.textSecondary),
          ),
          if (route.summary.isNotEmpty) ...[
            const SizedBox(height: Space.xs),
            Text(
              'via ${route.summary}',
              style: TextStyle(fontSize: 14, color: p.textSecondary),
            ),
          ],
          const SizedBox(height: Space.md),
          Wrap(
            spacing: Space.lg,
            runSpacing: Space.sm,
            children: [
              _Count(
                icon: Icons.photo_camera_rounded,
                color: p.camera,
                count: route.cameras,
                label: 'speed camera',
              ),
              _Count(
                icon: Icons.warning_amber_rounded,
                color: p.bump,
                count: route.bumps,
                label: 'speed bump',
              ),
              if (route.mobiles > 0)
                _Count(
                  icon: Icons.local_police_rounded,
                  color: p.danger,
                  count: route.mobiles,
                  label: 'police radar',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({
    required this.icon,
    required this.color,
    required this.count,
    required this.label,
  });
  final IconData icon;
  final Color color;
  final int count;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: count == 0 ? p.textTertiary : color),
        const SizedBox(width: 4),
        Text(
          '$count $label${count == 1 ? '' : 's'}',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: count == 0 ? p.textTertiary : p.text,
          ),
        ),
      ],
    );
  }
}

/// "Speed camera · at 12.4 km · in about 9 min" with its limit.
class _StopRow extends StatelessWidget {
  const _StopRow({required this.stop, required this.route});
  final RouteStop stop;
  final RouteOption route;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pt = stop.point;
    final mins = route.distanceM == 0
        ? 0
        : (route.durationS * stop.atM / route.distanceM / 60).round();
    final limit = pt.speedLimit;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Row(
        children: [
          PointTile(type: pt.type),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pt.type.label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: p.text,
                  ),
                ),
                Text(
                  [
                    'at ${formatDistance(stop.atM)}',
                    if (mins > 0) 'in about ${formatDuration(mins * 60)}',
                    if (pt.note != null && pt.note!.isNotEmpty) pt.note!,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
              ],
            ),
          ),
          if (limit != null) ...[
            const SizedBox(width: Space.sm),
            LimitSign(limit: limit, size: 34),
          ],
        ],
      ),
    );
  }
}

/// One turn-by-turn step with its maneuver icon.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});
  final RouteStep step;

  static IconData _icon(RouteStep s) {
    final m = s.modifier;
    switch (s.type) {
      case 'depart':
        return Icons.navigation_rounded;
      case 'arrive':
        return Icons.flag_rounded;
      case 'roundabout':
      case 'rotary':
      case 'roundabout turn':
        return m.contains('left')
            ? Icons.roundabout_left
            : Icons.roundabout_right;
      case 'merge':
        return Icons.merge_rounded;
      case 'fork':
        return m.contains('left')
            ? Icons.fork_left_rounded
            : Icons.fork_right_rounded;
      case 'on ramp':
      case 'off ramp':
        return m.contains('left')
            ? Icons.ramp_left_rounded
            : Icons.ramp_right_rounded;
    }
    return switch (m) {
      'left' => Icons.turn_left_rounded,
      'right' => Icons.turn_right_rounded,
      'slight left' => Icons.turn_slight_left_rounded,
      'slight right' => Icons.turn_slight_right_rounded,
      'sharp left' => Icons.turn_sharp_left_rounded,
      'sharp right' => Icons.turn_sharp_right_rounded,
      'uturn' => Icons.u_turn_left_rounded,
      _ => Icons.straight_rounded,
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final arrive = step.type == 'arrive';
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Row(
        children: [
          IconTile(
            color: arrive ? p.success : p.primary,
            soft: true,
            icon: _icon(step),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.instruction,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: p.text,
                  ),
                ),
                if (!arrive && step.distanceM > 0)
                  Text(
                    'then ${formatDistance(step.distanceM.toDouble())}',
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
