import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/custom_sound.dart';
import '../models/speed_point.dart';
import '../services/api_client.dart';
import '../services/sound_resolver.dart';
import '../theme/app_theme.dart';
import '../utils/geo.dart';
import 'hud.dart';
import 'sound_controls.dart';
import 'ui.dart';

enum PointSheetAction { saved, deleted, testDrive }

class PointSheetResult {
  const PointSheetResult(this.action, this.point);
  final PointSheetAction action;
  final SpeedPoint point;
}

typedef LatLngPair = ({double lat, double lng});

/// Where a new point goes.
enum PointPlace {
  /// The driver's GPS position.
  myLocation,

  /// A spot on the map (long-pressed, or the middle of the map).
  mapSpot,
}

/// Sheet to add a new point or edit / delete an existing one.
///
/// For a new point, [lat]/[lng] is a spot on the map and [myLocation] the
/// GPS position (null while waiting for GPS). The form lets the driver
/// choose between them, starting with [place]. [fromLongPress] names the
/// map spot "Pressed spot" instead of "Map center". With [presetDirection]
/// (adding at my location while driving) a new point starts as "one way",
/// in [myCourse]; otherwise "both ways".
Future<PointSheetResult?> showPointEditor(
  BuildContext context,
  AppController app, {
  SpeedPoint? existing,
  double? lat,
  double? lng,
  LatLngPair? myLocation,
  PointPlace place = PointPlace.mapSpot,
  bool fromLongPress = true,
  PointType initialType = PointType.camera,
  double? myCourse,
  bool presetDirection = false,
}) {
  final mapSpot = lat != null && lng != null ? (lat: lat, lng: lng) : null;
  final start = place == PointPlace.myLocation && myLocation != null
      ? PointPlace.myLocation
      : mapSpot != null
      ? PointPlace.mapSpot
      : PointPlace.myLocation;
  final at = start == PointPlace.myLocation ? myLocation : mapSpot;
  assert(existing != null || at != null, 'A new point needs a place');
  final point =
      existing ??
      SpeedPoint(
        id: newPointId(),
        type: initialType,
        lat: at!.lat,
        lng: at.lng,
        direction: presetDirection ? myCourse : null,
        shared: app.settings.sharePoints,
      );
  return showAppSheet<PointSheetResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PointEditor(
      app: app,
      initial: point,
      isNew: existing == null,
      myCourse: myCourse,
      myLocation: myLocation,
      mapSpot: mapSpot,
      place: start,
      fromLongPress: fromLongPress,
    ),
  );
}

class _PointEditor extends StatefulWidget {
  const _PointEditor({
    required this.app,
    required this.initial,
    required this.isNew,
    required this.place,
    required this.fromLongPress,
    this.myCourse,
    this.myLocation,
    this.mapSpot,
  });

  final AppController app;
  final SpeedPoint initial;
  final bool isNew;
  final double? myCourse;
  final LatLngPair? myLocation;
  final LatLngPair? mapSpot;
  final PointPlace place;
  final bool fromLongPress;

  @override
  State<_PointEditor> createState() => _PointEditorState();
}

class _PointEditorState extends State<_PointEditor> {
  /// Where a new point goes (ignored when editing).
  late PointPlace _place = widget.place;

  /// My GPS position; filled in when the first fix arrives while open.
  late LatLngPair? _gps = widget.myLocation;

  @override
  void initState() {
    super.initState();
    if (widget.isNew && _gps == null) widget.app.addListener(_waitForGps);
  }

  void _waitForGps() {
    final pos = widget.app.livePosition;
    if (pos == null || !mounted) return;
    widget.app.removeListener(_waitForGps);
    setState(() => _gps = (lat: pos.lat, lng: pos.lng));
  }

  LatLngPair get _location {
    if (widget.isNew) {
      final spot = _place == PointPlace.myLocation ? _gps : widget.mapSpot;
      if (spot != null) return spot;
    }
    return (lat: widget.initial.lat, lng: widget.initial.lng);
  }

  late PointType _type = widget.initial.type;
  late int? _limit = widget.initial.speedLimit;
  late double? _direction = widget.initial.direction;

  /// Last one-way direction, so switching Both ↔ One way keeps it.
  late double _lastDirection = widget.initial.direction ?? widget.myCourse ?? 0;
  late final _note = TextEditingController(text: widget.initial.note ?? '');

  /// This point's own sound and repeat count (null = use Settings).
  late CustomSound? _sound = widget.initial.sound;
  late int? _repeat = widget.initial.repeat;

  /// Shown to other drivers (own points).
  late bool _shared = widget.initial.shared;

  /// Another driver's point: only votes and the sound can change.
  bool get _community => widget.initial.community;

  /// The community point with its latest vote counts.
  late SpeedPoint _live = widget.initial;
  bool _voting = false;

  @override
  void dispose() {
    widget.app.removeListener(_waitForGps);
    _note.dispose();
    super.dispose();
  }

  /// Types this point can have. A new point can be anything; a fixed point
  /// can't become a police radar (it expires) or the other way round.
  List<PointType> get _types => widget.isNew
      ? PointType.values
      : [
          for (final t in PointType.values)
            if (t.temporary == widget.initial.type.temporary) t,
        ];

  SpeedPoint get _result => _community
      ? _live.copyWith(sound: () => _sound, repeat: () => _repeat)
      : widget.initial.copyWith(
          lat: _location.lat,
          lng: _location.lng,
          type: _type,
          speedLimit: () => _limit,
          // Police radar warns both ways and is always shared.
          direction: () => _type.temporary ? null : _direction,
          note: () => _note.text.trim().isEmpty ? null : _note.text.trim(),
          sound: () => _sound,
          repeat: () => _repeat,
          shared: _type.temporary || _shared,
          expiresAt: () => _type.temporary
              ? widget.initial.expiresAt ??
                    DateTime.now().add(policeRadarLifetime)
              : null,
        );

  Future<void> _showError(String message) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(message),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  /// "Still there" / "Gone"; tapping your current vote takes it back.
  Future<void> _vote(String vote) async {
    final next = _live.myVote == vote ? null : vote;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    setState(() => _voting = true);
    try {
      final updated = await widget.app.vote(_live, next);
      if (!mounted) return;
      if (updated == null) {
        // Close this sheet only (not something opened on top of it).
        if (route != null && route.isCurrent) {
          navigator.pop();
        } else if (route != null) {
          navigator.removeRoute(route);
        }
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Thanks! Enough drivers said it is gone, so it was taken off the map.',
            ),
          ),
        );
        return;
      }
      setState(() => _live = updated);
    } on ApiException catch (e) {
      if (mounted) await _showError(e.message);
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  Widget _buildCommunity(BuildContext context) {
    final p = context.palette;
    final pt = _live;
    final dir = pt.direction;
    final details = [
      pt.speedLimit != null ? 'Limit ${pt.speedLimit} km/h' : 'No speed limit',
      dir == null ? 'Both ways' : 'When driving ${compassName(dir)}',
    ].join(' · ');
    final votes = pt.confirms == 0 && pt.gones == 0
        ? 'Added by another driver. Nobody has confirmed it yet.'
        : 'Added by another driver · ${pt.confirms} said still there · '
              '${pt.gones} said gone';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Details'),
        AppCard(
          padding: const EdgeInsets.all(Space.lg),
          child: Row(
            children: [
              PointTile(type: pt.type, size: 40),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pt.type.label,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      style: TextStyle(fontSize: 13, color: p.textSecondary),
                    ),
                    if (pt.note case final note?) ...[
                      const SizedBox(height: 2),
                      Text(note, style: TextStyle(fontSize: 13, color: p.text)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SectionLabel('Is it still there?'),
        AppCard(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                votes,
                style: TextStyle(fontSize: 13, color: p.textSecondary),
              ),
              const SizedBox(height: Space.md),
              Row(
                children: [
                  Expanded(
                    child: _VoteButton(
                      label: 'Still there',
                      icon: Icons.check_circle_outline_rounded,
                      color: p.success,
                      selected: pt.myVote == 'confirm',
                      onTap: _voting ? null : () => _vote('confirm'),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: _VoteButton(
                      label: 'Gone',
                      icon: Icons.cancel_outlined,
                      color: p.danger,
                      selected: pt.myVote == 'gone',
                      onTap: _voting ? null : () => _vote('gone'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// "My location" or a spot on the map, for a new point.
  Widget _buildPlace(BuildContext context) {
    final p = context.palette;
    final hasGps = _gps != null;
    final hasSpot = widget.mapSpot != null;
    final spotLabel = widget.fromLongPress ? 'Pressed spot' : 'Map center';
    final spot = widget.fromLongPress
        ? 'The spot you long-pressed on the map.'
        : 'The middle of the map when you tapped Add.';
    final String hint;
    if (_place == PointPlace.myLocation) {
      hint = 'Your GPS position.';
    } else if (!hasGps) {
      hint = '$spot My location: waiting for GPS…';
    } else {
      hint = spot;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedControl<PointPlace>(
          value: _place,
          onChanged: (v) {
            if (v == PointPlace.myLocation && !hasGps) return;
            if (v == PointPlace.mapSpot && !hasSpot) return;
            setState(() => _place = v);
          },
          segments: [
            Segment(
              PointPlace.myLocation,
              'My location',
              icon: Icon(
                hasGps ? Icons.my_location_rounded : Icons.location_searching,
                size: 18,
                color: hasGps ? p.primary : p.textTertiary,
              ),
            ),
            Segment(
              PointPlace.mapSpot,
              spotLabel,
              icon: Icon(
                Icons.place_outlined,
                size: 18,
                color: hasSpot ? p.textSecondary : p.textTertiary,
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.sm),
        Text(hint, style: TextStyle(fontSize: 13, color: p.textSecondary)),
      ],
    );
  }

  Widget _buildSharing(BuildContext context) {
    final p = context.palette;
    return AppCard(
      child: SwitchListTile.adaptive(
        value: _shared,
        onChanged: (v) => setState(() => _shared = v),
        secondary: IconTile(
          color: p.primary,
          soft: true,
          icon: _shared ? Icons.public_rounded : Icons.lock_outline_rounded,
        ),
        title: const Text('Share with other drivers'),
        subtitle: Text(
          _shared
              ? 'Drivers near here get warned too.'
              : 'Private: only on your phones (still backed up).',
        ),
      ),
    );
  }

  Future<void> _pickSound() async {
    final choice = await chooseSound(
      context,
      library: widget.app.sounds,
      title: 'Sound for this ${_type.label.toLowerCase()}',
      resetLabel: _sound != null ? 'Use the sound from Settings' : null,
    );
    if (!mounted) return;
    switch (choice) {
      case PickedSound(:final sound):
        setState(() => _sound = sound);
      case ResetSound():
        setState(() => _sound = null);
      // Built-in sounds are chosen in Settings, not per point.
      case ChosenTone() || null:
    }
  }

  Widget _buildSound(BuildContext context) {
    final p = context.palette;
    final app = widget.app;
    final settings = app.settings;
    final first = settings.distancesFor(_type).first;
    final slots = SoundSlot.forApproach(_type, first);
    final defaultRepeat = settings.repeatFor(SoundSlot.type(_type));
    final hasOwn = app.sounds.has(_sound);
    final limit = _type != PointType.bump && _limit != null
        ? ' Limit $_limit.'
        : '';

    return AppCard(
      child: Column(
        children: [
          SoundRow(
            leading: IconTile(
              color: p.primary,
              soft: true,
              icon: hasOwn
                  ? Icons.music_note_rounded
                  : Icons.record_voice_over_outlined,
            ),
            title: hasOwn
                ? 'Own sound'
                : 'Same as all ${_type.label.toLowerCase()}s',
            custom: hasOwn,
            subtitle: hasOwn
                ? describeCustomSound(_sound!)
                : 'From Settings · ${describeResolved(app.voice.resolve(slots))}',
            onPlay: () => app.voice.previewSound(
              slots: slots,
              own: _sound,
              text: '${_type.label} in $first meters.$limit',
              repeat: _repeat ?? defaultRepeat,
            ),
            onChange: _pickSound,
          ),
          RepeatRow(
            value: _repeat,
            defaultTimes: defaultRepeat,
            onChanged: (v) => setState(() => _repeat = v),
          ),
        ],
      ),
    );
  }

  Future<SpeedPoint> _persist() async {
    final p = _result;
    if (widget.isNew) {
      await widget.app.addPoint(p);
    } else {
      await widget.app.updatePoint(p);
    }
    return p;
  }

  Future<void> _finish(PointSheetAction action) async {
    final SpeedPoint p;
    if (action == PointSheetAction.deleted) {
      await widget.app.deletePoint(widget.initial.id);
      p = widget.initial;
    } else {
      p = await _persist(); // test drive saves edits first
    }
    if (mounted) Navigator.pop(context, PointSheetResult(action, p));
  }

  void _setDirection(double? d) => setState(() {
    _direction = d;
    if (d != null) _lastDirection = d;
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final myCourse = widget.myCourse;
    final oneWay = _direction != null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(
              title: widget.isNew
                  ? 'New warning point'
                  : _community
                  ? 'From other drivers'
                  : 'Edit point',
              subtitle:
                  '${_location.lat.toStringAsFixed(5)}, '
                  '${_location.lng.toStringAsFixed(5)}'
                  '${widget.isNew || _community ? '' : '\nTo move it, hold and drag the pin on the map'}',
              onClose: () => Navigator.pop(context),
            ),

            if (widget.isNew) ...[
              const SectionLabel('Location'),
              _buildPlace(context),
            ],

            if (_community)
              _buildCommunity(context)
            else ...[
              if (_types.length > 1) ...[
                const SectionLabel('Type'),
                SegmentedControl<PointType>(
                  value: _type,
                  onChanged: (t) => setState(() => _type = t),
                  segments: [
                    for (final t in _types)
                      Segment(
                        t,
                        t.label,
                        icon: PointGlyph(
                          type: t,
                          size: 18,
                          color: _type == t ? p.colorFor(t) : p.textSecondary,
                        ),
                      ),
                  ],
                ),
              ],

              const SectionLabel('Speed limit'),
              AppCard(
                padding: const EdgeInsets.all(10),
                child: _LimitPicker(
                  value: _limit,
                  onChanged: (v) => setState(() => _limit = v),
                ),
              ),

              if (!_type.temporary) ...[
                const SectionLabel('Warn when driving'),
                SegmentedControl<bool>(
                  value: oneWay,
                  onChanged: (one) =>
                      _setDirection(one ? _lastDirection : null),
                  segments: const [
                    Segment(false, 'Both ways'),
                    Segment(true, 'One way'),
                  ],
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: oneWay
                      ? Padding(
                          padding: const EdgeInsets.only(top: Space.lg),
                          child: Column(
                            children: [
                              CompassPicker(
                                value: _direction,
                                onChanged: _setDirection,
                              ),
                              if (myCourse != null) ...[
                                const SizedBox(height: Space.md),
                                AppChip(
                                  icon: Icons.navigation_rounded,
                                  label:
                                      'My direction · ${compassName(myCourse)}',
                                  selected: _direction == myCourse,
                                  onTap: () => _setDirection(myCourse),
                                ),
                              ],
                            ],
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],

              const SectionLabel('Note'),
              TextField(
                controller: _note,
                maxLength: maxNoteLength,
                buildCounter:
                    (
                      context, {
                      required currentLength,
                      required isFocused,
                      maxLength,
                    }) => currentLength > maxNoteLength - 40
                    ? Text('$currentLength / $maxLength')
                    : null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Optional, e.g. after the bridge',
                ),
              ),

              const SectionLabel('Sharing'),
              if (_type.temporary)
                AppCard(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Text(
                    'Police radar is shared with every driver and warns both '
                    'ways. It leaves the map after '
                    '${policeRadarLifetime.inHours} hours, unless drivers '
                    'confirm it is still there.',
                    style: TextStyle(fontSize: 14, color: p.textSecondary),
                  ),
                )
              else
                _buildSharing(context),
            ],

            const SectionLabel('Warning sound'),
            _buildSound(context),

            const SizedBox(height: Space.xxl),
            Row(
              children: [
                if (!widget.isNew && !_community) ...[
                  Tooltip(
                    message: 'Delete',
                    child: _DeleteButton(
                      onTap: () => _finish(PointSheetAction.deleted),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                ],
                Expanded(
                  flex: 2,
                  child: OutlinedButton.icon(
                    onPressed: () => _finish(PointSheetAction.testDrive),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text(
                      'Test',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  flex: 3,
                  child: FilledButton(
                    onPressed: () => _finish(PointSheetAction.saved),
                    child: const Text(
                      'Save',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DeleteButton extends StatelessWidget {
  const _DeleteButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.danger.withValues(alpha: 0.12),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox.square(
          dimension: 52,
          child: Icon(Icons.delete_outline_rounded, color: p.danger),
        ),
      ),
    );
  }
}

/// Row of real-looking speed-limit signs to tap.
class _LimitPicker extends StatelessWidget {
  const _LimitPicker({required this.value, required this.onChanged});

  static const _limits = [20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 140];

  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final items = <int?>[
      null,
      ..._limits,
      ?(_limits.contains(value) ? null : value),
    ];
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: Space.sm),
        itemBuilder: (context, i) {
          final v = items[i];
          final selected = v == value;
          return Semantics(
            button: true,
            selected: selected,
            label: v == null ? 'No speed limit' : 'Limit $v',
            child: GestureDetector(
              onTap: () => onChanged(v),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? p.primary : Colors.transparent,
                    width: 2.5,
                  ),
                ),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 160),
                  opacity: selected || value == null && v == null ? 1 : 0.8,
                  child: v == null
                      ? Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: p.fill,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'None',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                              color: p.textSecondary,
                            ),
                          ),
                        )
                      : LimitSign(limit: v, size: 52),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Compass to choose the travel direction a point applies to.
/// Tap a direction (N, NE, ...) or the middle for both ways.
class CompassPicker extends StatelessWidget {
  const CompassPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = 208,
  });

  final double? value;
  final ValueChanged<double?> onChanged;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final v = value;
    final r = size / 2 - 24;
    // Center keeps the dial its exact size even if the parent is wider.
    return Center(
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.surface,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            for (var i = 0; i < 8; i++)
              Positioned(
                left: size / 2 + r * math.sin(i * math.pi / 4) - 20,
                top: size / 2 - r * math.cos(i * math.pi / 4) - 20,
                child: _DirButton(
                  label: compassName(i * 45.0),
                  selected: v != null && angleDifference(v, i * 45.0) < 0.5,
                  onTap: () => onChanged(i * 45.0),
                ),
              ),
            Center(
              child: Semantics(
                button: true,
                label: 'Both ways',
                child: GestureDetector(
                  onTap: () => onChanged(null),
                  child: Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      color: p.bg,
                      shape: BoxShape.circle,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedRotation(
                          turns: (v ?? 0) / 360,
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            v == null
                                ? Icons.swap_vert_rounded
                                : Icons.navigation_rounded,
                            size: 30,
                            color: v == null ? p.textSecondary : p.primary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          v == null
                              ? 'Both ways'
                              : '${compassName(v)} ${v.round()}°',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: p.text,
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
    );
  }
}

class _DirButton extends StatelessWidget {
  const _DirButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? p.primary : Colors.transparent,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: label.length > 1 ? 12 : 14,
              color: selected
                  ? p.onPrimary
                  : label == 'N'
                  ? p.camera
                  : p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// "Still there" / "Gone" button; filled when it is your vote.
class _VoteButton extends StatelessWidget {
  const _VoteButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    return selected
        ? FilledButton.icon(
            onPressed: onTap,
            style: FilledButton.styleFrom(backgroundColor: color),
            icon: Icon(icon),
            label: text,
          )
        : OutlinedButton.icon(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              foregroundColor: color,
              side: BorderSide(color: color.withValues(alpha: 0.5)),
            ),
            icon: Icon(icon),
            label: text,
          );
  }
}
