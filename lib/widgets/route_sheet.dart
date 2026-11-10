import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/route_plan.dart';
import '../models/speed_point.dart';
import '../screens/route_details_screen.dart';
import '../screens/search_screen.dart';
import '../theme/app_theme.dart';
import '../utils/geo.dart';
import 'ui.dart';

/// "47 min", "2 h 17 min".
String formatDuration(int seconds) {
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '${minutes < 1 ? 1 : minutes} min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// The ways to drive to [AppController.destination]. The map behind stays
/// visible (it shows the routes). Returns true when the driver taps Start.
Future<bool> showRouteOptions(BuildContext context, AppController app) async {
  final size = MediaQuery.sizeOf(context);
  final started = await showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    barrierColor: Colors.transparent,
    constraints: BoxConstraints(maxHeight: size.height * routeSheetHeight),
    builder: (_) => _RouteSheet(app: app),
  );
  return started ?? false;
}

/// Part of the screen the route sheet can cover (the map keeps the rest).
const routeSheetHeight = 0.52;

class _RouteSheet extends StatelessWidget {
  const _RouteSheet({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final dest = app.destination;
        final options = app.routeOptions;
        if (dest == null || options.isEmpty) return const SizedBox(height: 120);
        final pos = app.position;
        final about = [
          placeKindLabel(dest.kind),
          if (dest.address.isNotEmpty) dest.address,
          if (pos != null)
            '${formatDistance(distanceMeters(pos.lat, pos.lng, dest.lat, dest.lng))} away',
        ].join(' · ');
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.xl,
                0,
                Space.xl,
                Space.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SheetHeader(
                    title: 'To ${dest.name}',
                    onClose: () => Navigator.pop(context, false),
                  ),
                  const SizedBox(height: 3),
                  // One line, so the ways below keep their room.
                  Text(
                    options.length == 1
                        ? about
                        : '$about · ${options.length} ways',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: context.palette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: Space.xl),
                itemCount: options.length,
                separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
                itemBuilder: (context, i) => _RouteCard(
                  option: options[i],
                  fastest: i == 0 && options.length > 1,
                  selected: i == app.selectedRoute,
                  onTap: () => app.selectRoute(i),
                  onDetails: () async {
                    app.selectRoute(i);
                    final start = await showRouteDetails(context, app, i);
                    if (start && context.mounted) Navigator.pop(context, true);
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.xl,
                Space.md,
                Space.xl,
                Space.lg,
              ),
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.navigation_rounded),
                label: const Text('Start'),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.option,
    required this.fastest,
    required this.selected,
    required this.onTap,
    required this.onDetails,
  });

  final RouteOption option;
  final bool fastest;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final none =
        option.cameras == 0 && option.bumps == 0 && option.mobiles == 0;
    return Semantics(
      selected: selected,
      button: true,
      child: AppCard(
        onTap: onTap,
        color: selected ? p.primarySoft : null,
        borderColor: selected ? p.primary : null,
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Time and distance shorten (…) before the badge is squeezed.
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: formatDuration(option.durationS),
                          style: numberStyle(
                            24,
                            color: selected ? p.primary : p.text,
                          ),
                        ),
                        TextSpan(
                          text:
                              '  ${formatDistance(option.distanceM.toDouble())}',
                          style: TextStyle(
                            fontSize: 15,
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (fastest)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: p.success.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Fastest',
                      style: TextStyle(
                        color: p.success,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
              ],
            ),
            if (option.summary.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                'via ${option.summary}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: p.textSecondary),
              ),
            ],
            const SizedBox(height: Space.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: none
                      ? Text(
                          'No speed cameras or bumps known on this way',
                          style: TextStyle(fontSize: 13, color: p.textTertiary),
                        )
                      : Wrap(
                          spacing: Space.md,
                          runSpacing: Space.xs,
                          children: [
                            _Count(
                              type: PointType.camera,
                              count: option.cameras,
                              label: 'camera',
                            ),
                            _Count(
                              type: PointType.bump,
                              count: option.bumps,
                              label: 'speed bump',
                            ),
                            if (option.mobiles > 0)
                              _Count(
                                count: option.mobiles,
                                label: 'police radar',
                                icon: Icons.local_police_rounded,
                              ),
                          ],
                        ),
                ),
                TextButton.icon(
                  onPressed: onDetails,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                  ),
                  icon: const Icon(Icons.info_outline_rounded, size: 18),
                  label: const Text('Details'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({
    this.type,
    required this.count,
    required this.label,
    this.icon,
  });
  final PointType? type;
  final int count;
  final String label;

  /// Used when there is no [type] (police radars).
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (type case final t?)
          PointGlyph(
            type: t,
            size: 16,
            color: count == 0 ? p.textTertiary : p.colorFor(t),
          )
        else
          Icon(icon, size: 16, color: count == 0 ? p.textTertiary : p.danger),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '$count $label${count == 1 ? '' : 's'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: count == 0 ? p.textTertiary : p.text,
            ),
          ),
        ),
      ],
    );
  }
}
