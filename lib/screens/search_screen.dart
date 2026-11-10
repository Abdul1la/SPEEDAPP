import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/route_plan.dart';
import '../services/api_client.dart';
import '../services/storage.dart';
import '../theme/app_theme.dart';
import '../utils/geo.dart';
import '../widgets/ui.dart';

/// Opens place search. Returns the chosen place, or null.
Future<Place?> showPlaceSearch(BuildContext context, AppController app) =>
    Navigator.push<Place>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SearchScreen(app: app),
      ),
    );

/// Search as you type ("Duhok", a street, a shop...), with recent places.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.app, this.storage});

  final AppController app;

  /// Where recent searches are kept (tests pass a memory one).
  final Storage? storage;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const _maxRecent = 8;
  static const _debounce = Duration(milliseconds: 350);

  final _query = TextEditingController();
  late final Storage _storage = widget.storage ?? Storage();
  List<Place> _recent = [];
  List<Place> _results = [];
  bool _loading = false;
  String? _error;
  Timer? _timer;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _storage
        .loadRecentPlaces()
        .then((r) {
          if (mounted) setState(() => _recent = r);
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _timer?.cancel();
    final q = text.trim();
    if (q.length < 2) {
      setState(() {
        _results = [];
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() => _loading = true);
    _timer = Timer(_debounce, () => _search(q));
  }

  Future<void> _search(String q) async {
    final id = ++_request;
    try {
      final found = await widget.app.searchPlaces(q);
      if (!mounted || id != _request) return; // a newer search is running
      setState(() {
        _results = found;
        _loading = false;
        _error = found.isEmpty ? 'Nothing found for "$q".' : null;
      });
    } on ApiException catch (e) {
      if (!mounted || id != _request) return;
      setState(() {
        _results = [];
        _loading = false;
        _error = e.offline
            ? 'No internet connection. Search needs internet.'
            : e.message;
      });
    }
  }

  Future<void> _pick(Place place) async {
    final recent = [
      place,
      ..._recent.where((r) => r.id != place.id),
    ].take(_maxRecent).toList();
    unawaited(_storage.saveRecentPlaces(recent).catchError((_) {}));
    if (mounted) Navigator.pop(context, place);
  }

  Future<void> _clearRecent() async {
    setState(() => _recent = []);
    await _storage.saveRecentPlaces([]).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final showRecent = _query.text.trim().length < 2;
    final items = showRecent ? _recent : _results;

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.sm,
                Space.sm,
                Space.md,
                Space.sm,
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _query,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onChanged: _onChanged,
                      onSubmitted: (t) {
                        _timer?.cancel();
                        if (t.trim().length >= 2) _search(t.trim());
                      },
                      decoration: InputDecoration(
                        hintText: 'Search places, e.g. Duhok',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _query.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear',
                                onPressed: () {
                                  _query.clear();
                                  _onChanged('');
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_loading)
              const LinearProgressIndicator(minHeight: 2)
            else
              const SizedBox(height: 2),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.md,
                  Space.lg,
                  Space.xl,
                ),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (showRecent && _recent.isNotEmpty)
                    Row(
                      children: [
                        const Expanded(
                          child: SectionLabel(
                            'Recent',
                            padding: EdgeInsets.only(bottom: Space.sm),
                          ),
                        ),
                        TextButton(
                          onPressed: _clearRecent,
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                  if (showRecent && _recent.isEmpty)
                    _Hint(
                      icon: Icons.travel_explore_rounded,
                      text:
                          'Type a city, street or place. Then pick the way to drive there; the app shows the speed cameras and bumps on each way.',
                    ),
                  if (!showRecent && _error != null)
                    _Hint(icon: Icons.search_off_rounded, text: _error!),
                  if (items.isNotEmpty)
                    AppCard(
                      child: Column(
                        children: [
                          for (var i = 0; i < items.length; i++) ...[
                            if (i > 0) const Divider(indent: 60),
                            _PlaceRow(
                              place: items[i],
                              recent: showRecent,
                              from: switch (widget.app.position) {
                                final pos? => (lat: pos.lat, lng: pos.lng),
                                null => null,
                              },
                              onTap: () => _pick(items[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.place,
    required this.recent,
    required this.onTap,
    this.from,
  });

  final Place place;
  final bool recent;
  final VoidCallback onTap;
  final ({double lat, double lng})? from;

  static IconData _icon(String kind) => switch (kind) {
    'city' ||
    'town' ||
    'village' ||
    'hamlet' ||
    'suburb' ||
    'neighbourhood' ||
    'state' ||
    'county' => Icons.location_city_rounded,
    'motorway' ||
    'trunk' ||
    'primary' ||
    'secondary' ||
    'tertiary' ||
    'residential' ||
    'road' ||
    'street' => Icons.route_rounded,
    'restaurant' || 'cafe' || 'fast_food' => Icons.restaurant_rounded,
    'fuel' => Icons.local_gas_station_rounded,
    'hospital' || 'clinic' || 'pharmacy' => Icons.local_hospital_rounded,
    'school' || 'university' || 'college' => Icons.school_rounded,
    'hotel' => Icons.hotel_rounded,
    'mosque' || 'church' || 'place_of_worship' => Icons.mosque_rounded,
    _ => Icons.place_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final f = from;
    final km = f == null
        ? null
        : distanceMeters(f.lat, f.lng, place.lat, place.lng) / 1000;
    final distance = km == null
        ? null
        : (km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        child: Row(
          children: [
            IconTile(
              color: recent ? p.textSecondary : p.primary,
              soft: true,
              icon: recent ? Icons.history_rounded : _icon(place.kind),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                  if (place.address.isNotEmpty)
                    Text(
                      place.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: p.textSecondary),
                    ),
                ],
              ),
            ),
            if (distance != null) ...[
              const SizedBox(width: Space.sm),
              Text(
                distance,
                style: TextStyle(fontSize: 13, color: p.textTertiary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: Space.xl,
        horizontal: Space.md,
      ),
      child: Column(
        children: [
          Icon(icon, size: 40, color: p.textTertiary),
          const SizedBox(height: Space.md),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: p.textSecondary),
          ),
        ],
      ),
    );
  }
}
