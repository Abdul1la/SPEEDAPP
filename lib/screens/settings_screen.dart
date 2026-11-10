import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../models/app_settings.dart';
import '../models/custom_sound.dart';
import '../models/speed_point.dart';
import '../models/warning_tone.dart';
import '../services/api_client.dart';
import '../services/sound_resolver.dart';
import '../theme/app_theme.dart';
import '../widgets/sound_controls.dart';
import '../widgets/ui.dart';

/// The parts of Settings, each on its own page.
enum SettingsSection {
  warnings('Warnings', Icons.notifications_active_rounded, Color(0xFFFF3B30)),
  sounds('Warning sounds', Icons.volume_up_rounded, Color(0xFFFF2D55)),
  map('Map & screen', Icons.map_rounded, Color(0xFF34C759)),
  radar('Police radar', Icons.local_police_rounded, Color(0xFF5856D6)),
  points('Your points', Icons.place_rounded, Color(0xFFFF9500)),
  account('Account & backup', Icons.cloud_rounded, Color(0xFF007AFF));

  const SettingsSection(this.title, this.icon, this.color);
  final String title;
  final IconData icon;
  final Color color;
}

/// Settings: a short home page (account, quick switches, sections), with
/// each section on its own page. On wide screens (tablets, landscape) the
/// sections stay on the left and the open one shows on the right.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.app});

  final AppController app;

  /// From this width the sections list and the open section sit side by side.
  static const twoPaneWidth = 840.0;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsSection _open = SettingsSection.warnings;

  AppController get app => widget.app;

  void _openPage(BuildContext context, SettingsSection section) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _SectionPage(app: app, section: section),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= SettingsScreen.twoPaneWidth;
          return ListenableBuilder(
            listenable: app,
            builder: (context, _) {
              final home = _Home(
                app: app,
                selected: wide ? _open : null,
                onOpen: (section) => wide
                    ? setState(() => _open = section)
                    : _openPage(context, section),
              );
              if (!wide) return home;
              return Row(
                children: [
                  SizedBox(width: 380, child: home),
                  VerticalDivider(width: 1, thickness: 1, color: p.border),
                  Expanded(
                    child: _SectionPage(
                      key: ValueKey(_open),
                      app: app,
                      section: _open,
                      embedded: true,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Side padding that keeps content at a readable width on big screens.
EdgeInsets _readable(double width, {double top = 0, double bottom = 0}) {
  const maxContent = 680.0;
  final side = width > maxContent + 2 * Space.lg
      ? (width - maxContent) / 2
      : Space.lg;
  return EdgeInsets.fromLTRB(side, top, side, bottom);
}

/// Settings home: account, quick switches, the sections, about.
class _Home extends StatelessWidget {
  const _Home({required this.app, required this.onOpen, this.selected});

  final AppController app;
  final ValueChanged<SettingsSection> onOpen;

  /// The section shown next to the list (wide screens), highlighted.
  final SettingsSection? selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = app.settings;
    void set(AppSettings next) {
      HapticFeedback.selectionClick();
      app.updateSettings(next);
    }

    return LayoutBuilder(
      builder: (context, box) => CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('Settings'),
            backgroundColor: p.bg,
            surfaceTintColor: Colors.transparent,
          ),
          SliverPadding(
            padding: _readable(box.maxWidth, bottom: Space.xxl * 2),
            sliver: SliverList.list(
              children: [
                _AccountCard(
                  app: app,
                  onTap: () => onOpen(SettingsSection.account),
                ),
                const SectionLabel(
                  'Quick settings',
                  padding: EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.xxl,
                    Space.lg,
                    Space.sm,
                  ),
                ),
                _QuickGrid(
                  tiles: [
                    _QuickToggle(
                      icon: s.muted
                          ? Icons.volume_off_rounded
                          : Icons.record_voice_over_rounded,
                      color: const Color(0xFFFF2D55),
                      label: 'Voice warnings',
                      on: !s.muted,
                      onChanged: (v) => set(s.copyWith(muted: !v)),
                    ),
                    _QuickToggle(
                      icon: Icons.light_mode_rounded,
                      color: const Color(0xFFFF9500),
                      label: 'Keep screen on',
                      on: s.keepScreenOn,
                      onChanged: (v) => set(s.copyWith(keepScreenOn: v)),
                    ),
                    _QuickToggle(
                      icon: Icons.local_police_rounded,
                      color: p.radar,
                      label: 'Find police radar',
                      on: s.findRadar,
                      onChanged: (v) => set(s.copyWith(findRadar: v)),
                    ),
                    _QuickToggle(
                      icon: Icons.public_rounded,
                      color: p.success,
                      label: 'Share new points',
                      on: s.sharePoints,
                      onChanged: (v) => set(s.copyWith(sharePoints: v)),
                    ),
                  ],
                ),
                const SizedBox(height: Space.xxl),
                AppCard(
                  radius: Radii.lg,
                  child: Column(
                    children: [
                      for (final section in SettingsSection.values) ...[
                        if (section != SettingsSection.values.first)
                          const Divider(indent: 60),
                        _SectionRow(
                          section: section,
                          summary: _summary(section, app),
                          selected: section == selected,
                          onTap: () => onOpen(section),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Space.xxl),
                const _About(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _distances(List<int> meters) => meters
    .map(
      (d) => d >= 1000
          ? '${(d / 1000).toStringAsFixed(d % 1000 == 0 ? 0 : 1)} km'
          : '$d',
    )
    .join(', ');

/// One line under each section: what it is set to now.
String _summary(SettingsSection section, AppController app) {
  final s = app.settings;
  int count(PointType t) => app.points.where((x) => x.type == t).length;
  String plural(int n, String one) => '$n $one${n == 1 ? '' : 's'}';
  switch (section) {
    case SettingsSection.warnings:
      final camera = _distances(s.cameraDistances);
      return 'Cameras $camera m · over limit +${s.overSpeedTolerance} km/h';
    case SettingsSection.sounds:
      if (s.muted) return 'Voice warnings are off';
      final tone = describeTone(
        s.toneFor(PointType.camera),
        speakDistance: s.speakDistance,
      );
      return 'Cameras: $tone';
    case SettingsSection.map:
      final look = switch (s.mapLook) {
        MapLook.auto => 'Automatic look',
        MapLook.light => 'Light map',
        MapLook.dark => 'Dark map',
        MapLook.standard => 'Google map',
      };
      return '$look · ${s.keepScreenOn ? 'screen stays on' : 'screen may sleep'}';
    case SettingsSection.radar:
      return s.findRadar ? 'Found automatically from slowdowns' : 'Off';
    case SettingsSection.points:
      final cams = count(PointType.camera);
      final bumps = count(PointType.bump);
      if (cams + bumps == 0) return 'None added yet';
      return '${plural(cams, 'camera')} · ${plural(bumps, 'bump')}';
    case SettingsSection.account:
      final account = app.sync.account;
      if (account != null && !account.isAnonymous) {
        return 'Backed up to ${account.email}';
      }
      return 'Not backed up yet';
  }
}

/// Sync state in words, and the color of its dot.
(String, Color) _syncStatus(BuildContext context, AppController app) {
  final p = context.palette;
  final sync = app.sync;
  final pending = sync.pending;
  if (sync.syncing) return ('Syncing…', p.primary);
  if (sync.error != null) return (sync.error!, p.warning);
  if (sync.lastSyncAt case final at?) {
    final n = app.community.length;
    final up = pending > 0
        ? ' · $pending change${pending == 1 ? '' : 's'} to upload'
        : '';
    return (
      'Synced ${_ago(at)} · $n point${n == 1 ? '' : 's'} from other drivers$up',
      p.success,
    );
  }
  return ('Not synced yet', p.textTertiary);
}

/// Who is signed in and how the backup is doing. Opens Account & backup.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.app, required this.onTap});
  final AppController app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sync = app.sync;
    final account = sync.account;
    final email = account?.email ?? sync.signedOutEmail;
    final (status, dot) = _syncStatus(context, app);
    return AppCard(
      radius: Radii.lg,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.lg,
        Space.sm,
        Space.lg,
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.primarySoft,
              shape: BoxShape.circle,
            ),
            child: email != null && email.isNotEmpty
                ? Text(
                    email[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: p.primary,
                    ),
                  )
                : Icon(Icons.smartphone_rounded, color: p.primary, size: 26),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  email ?? 'This phone only',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: dot,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: p.textSecondary),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (sync.syncing)
            const Padding(
              padding: EdgeInsets.all(Space.md),
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            )
          else
            IconButton(
              tooltip: 'Sync now',
              onPressed: sync.syncNow,
              icon: Icon(Icons.sync_rounded, color: p.primary),
            ),
          Icon(Icons.chevron_right_rounded, color: p.textTertiary),
        ],
      ),
    );
  }
}

/// Quick switches in a grid: 2 across on phones, 4 on wider screens.
class _QuickGrid extends StatelessWidget {
  const _QuickGrid({required this.tiles});
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final across = box.maxWidth >= 560 ? 4 : 2;
        return Column(
          children: [
            for (var i = 0; i < tiles.length; i += across) ...[
              if (i > 0) const SizedBox(height: Space.md),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var j = i; j < i + across; j++) ...[
                      if (j > i) const SizedBox(width: Space.md),
                      Expanded(
                        child: j < tiles.length ? tiles[j] : const SizedBox(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A big on / off tile: colored when on.
class _QuickToggle extends StatelessWidget {
  const _QuickToggle({
    required this.icon,
    required this.color,
    required this.label,
    required this.on,
    required this.onChanged,
  });

  final IconData icon;
  final Color color;
  final String label;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      toggled: on,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: () => onChanged(!on),
      child: AppCard(
        radius: Radii.lg,
        onTap: () => onChanged(!on),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(
                  color: on ? color : p.textTertiary,
                  icon: icon,
                  size: 34,
                ),
                const Spacer(),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: on ? color : p.fill,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    on ? 'On' : 'Off',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: on ? Colors.white : p.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A section on the home page: icon, name, what it is set to, chevron.
class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.section,
    required this.summary,
    required this.selected,
    required this.onTap,
  });

  final SettingsSection section;
  final String summary;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      selected: selected,
      child: Material(
        color: selected ? p.primarySoft : Colors.transparent,
        child: _Row(
          icon: section.icon,
          color: section.color,
          title: section.title,
          subtitle: summary,
          onTap: onTap,
          trailing: Icon(Icons.chevron_right_rounded, color: p.textTertiary),
        ),
      ),
    );
  }
}

/// One section's settings: its own page on phones, the right side on
/// tablets ([embedded]).
class _SectionPage extends StatelessWidget {
  const _SectionPage({
    super.key,
    required this.app,
    required this.section,
    this.embedded = false,
  });

  final AppController app;
  final SettingsSection section;
  final bool embedded;

  List<Widget> _content(BuildContext context) {
    final p = context.palette;
    final s = app.settings;
    void set(AppSettings next) => app.updateSettings(next);
    switch (section) {
      case SettingsSection.warnings:
        return [
          _Group(
            title: 'Warn me before',
            footer:
                'Pick one or more distances for each kind of point. '
                'The app warns you at each of them.',
            children: [
              for (final type in PointType.values)
                _DistanceRow(
                  type: type,
                  values: s.distancesFor(type),
                  onChanged: (v) => set(switch (type) {
                    PointType.camera => s.copyWith(cameraDistances: v),
                    PointType.bump => s.copyWith(bumpDistances: v),
                    PointType.mobile => s.copyWith(mobileDistances: v),
                  }),
                ),
            ],
          ),
          _Group(
            title: 'Speed limit',
            children: [
              _ToleranceRow(
                value: s.overSpeedTolerance,
                onChanged: (v) => set(s.copyWith(overSpeedTolerance: v)),
              ),
            ],
          ),
        ];
      case SettingsSection.sounds:
        return [
          _Group(
            children: [
              _SwitchRow(
                icon: s.muted
                    ? Icons.volume_off_rounded
                    : Icons.record_voice_over_rounded,
                color: const Color(0xFFFF2D55),
                title: 'Voice warnings',
                subtitle: s.muted
                    ? 'Off: only the warning card shows'
                    : 'Sounds and voice play for each warning',
                value: !s.muted,
                onChanged: (v) => set(s.copyWith(muted: !v)),
              ),
            ],
          ),
          _SoundsSection(app: app),
        ];
      case SettingsSection.map:
        return [
          _Group(
            title: 'Map style',
            footer: 'Automatic: light by day, dark at night.',
            children: [
              Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: Row(
                  children: [
                    for (final look in MapLook.values) ...[
                      if (look != MapLook.values.first)
                        const SizedBox(width: Space.sm),
                      Expanded(
                        child: _LookTile(
                          look: look,
                          selected: s.mapLook == look,
                          onTap: () => set(s.copyWith(mapLook: look)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          _Group(
            title: 'Screen',
            children: [
              _SwitchRow(
                icon: Icons.light_mode_rounded,
                color: p.warning,
                title: 'Keep screen on',
                subtitle: 'While the app is open',
                value: s.keepScreenOn,
                onChanged: (v) => set(s.copyWith(keepScreenOn: v)),
              ),
            ],
          ),
        ];
      case SettingsSection.radar:
        return [_RadarSection(app: app)];
      case SettingsSection.points:
        return [_PointsSection(app: app)];
      case SettingsSection.account:
        return [_AccountSection(app: app)];
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) => LayoutBuilder(
          builder: (context, box) => CustomScrollView(
            slivers: [
              SliverAppBar.large(
                title: Text(section.title),
                automaticallyImplyLeading: !embedded,
                backgroundColor: p.bg,
                surfaceTintColor: Colors.transparent,
              ),
              SliverPadding(
                padding: _readable(box.maxWidth, bottom: Space.xxl * 2),
                sliver: SliverList.list(children: _content(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Version and the credits the data and car picture licenses ask for.
class _About extends StatelessWidget {
  const _About();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final small = TextStyle(color: p.textTertiary, fontSize: 12, height: 1.5);
    return Column(
      children: [
        Text(
          'Speed Alert 1.0',
          style: TextStyle(
            color: p.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: Space.xs),
        // Required by the OpenStreetMap license (ODbL) for the imported
        // cameras and bumps, and by CC BY 4.0 for the 3D model the car
        // picture is made from (see assets/images/CREDITS.md).
        Text(
          'Camera and bump data © OpenStreetMap contributors\n'
          'Car: "2024 BYD Seal" 3D model by 007 (Sketchfab), CC BY 4.0',
          textAlign: TextAlign.center,
          style: small,
        ),
      ],
    );
  }
}

// ---- Building blocks -------------------------------------------------------

/// A titled group of rows in one card (like an iOS inset-grouped list).
class _Group extends StatelessWidget {
  const _Group({required this.children, this.title, this.footer});
  final String? title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: Space.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(left: Space.lg, bottom: Space.sm),
              child: Text(
                title!,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                ),
              ),
            ),
          AppCard(
            radius: Radii.lg,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const Divider(indent: 60),
                  children[i],
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.sm,
                Space.lg,
                0,
              ),
              child: Text(
                footer!,
                style: TextStyle(fontSize: 13, color: p.textTertiary),
              ),
            ),
        ],
      ),
    );
  }
}

class _RowTitle extends StatelessWidget {
  const _RowTitle({
    required this.title,
    this.icon,
    this.color,
    this.leading,
    this.subtitle,
    this.titleColor,
  });

  final String title;
  final IconData? icon;
  final Color? color;
  final Widget? leading;
  final String? subtitle;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        leading ?? IconTile(color: color ?? p.primary, icon: icon),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: titleColor ?? p.text,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    this.icon,
    this.color,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.titleColor,
  });

  final String title;
  final IconData? icon;
  final Color? color;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: _RowTitle(
                  title: title,
                  icon: icon,
                  color: color,
                  subtitle: subtitle,
                  titleColor: titleColor,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: Space.sm),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _Row(
    icon: icon,
    color: color,
    title: title,
    subtitle: subtitle,
    onTap: () => onChanged(!value),
    trailing: Switch.adaptive(value: value, onChanged: onChanged),
  );
}

/// Warning distances as chips (pick as many as you like).
class _DistanceRow extends StatelessWidget {
  const _DistanceRow({
    required this.type,
    required this.values,
    required this.onChanged,
  });

  static const _presets = [1000, 800, 600, 500, 400, 300, 200, 150, 100, 50];

  final PointType type;
  final List<int> values;
  final ValueChanged<List<int>> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final options = {..._presets, ...values}.toList()
      ..sort((a, b) => b.compareTo(a));
    final n = values.length;
    return Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RowTitle(
            leading: PointTile(type: type),
            title: type.label,
            subtitle: '$n warning${n == 1 ? '' : 's'}',
          ),
          const SizedBox(height: Space.md),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              for (final d in options)
                AppChip(
                  label: d >= 1000 ? '${d ~/ 1000} km' : '$d m',
                  selected: values.contains(d),
                  color: p.primary,
                  onTap: () {
                    final next = {...values};
                    next.contains(d) ? next.remove(d) : next.add(d);
                    if (next.isEmpty) return; // keep at least one
                    onChanged(next.toList()..sort((a, b) => b.compareTo(a)));
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ToleranceRow extends StatelessWidget {
  const _ToleranceRow({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.lg,
        Space.lg,
        Space.sm,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _RowTitle(
                  icon: Icons.speed_rounded,
                  color: p.danger,
                  title: '“Slow down” warning',
                  subtitle: 'When you are over the limit by',
                ),
              ),
              Text(
                '+$value km/h',
                style: numberStyle(17, color: p.text, weight: FontWeight.w600),
              ),
            ],
          ),
          Slider(
            value: value.toDouble(),
            min: 0,
            max: 20,
            divisions: 20,
            label: '+$value km/h',
            onChanged: (v) => onChanged(v.round()),
          ),
        ],
      ),
    );
  }
}

/// Small preview of each appearance option.
class _LookTile extends StatelessWidget {
  const _LookTile({
    required this.look,
    required this.selected,
    required this.onTap,
  });

  final MapLook look;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final name = switch (look) {
      MapLook.auto => 'Auto',
      MapLook.light => 'Light',
      MapLook.dark => 'Dark',
      MapLook.standard => 'Google',
    };
    return Semantics(
      button: true,
      selected: selected,
      label: '$name appearance',
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 76,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(
                  color: selected ? p.primary : p.border,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.md - 3),
                child: CustomPaint(
                  painter: _MiniMapPainter(look),
                  size: Size.infinite,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? p.text : p.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniMapPainter extends CustomPainter {
  const _MiniMapPainter(this.look);
  final MapLook look;

  static const _lightColors = (
    Color(0xFFF3F4F6),
    Color(0xFFB9DAF3),
    Colors.white,
    Color(0xFFFFE7A8),
  );
  static const _darkColors = (
    Color(0xFF1B1D21),
    Color(0xFF0F1720),
    Color(0xFF33373E),
    Color(0xFF454A53),
  );
  static const _googleColors = (
    Color(0xFFF1F3F4),
    Color(0xFFAADAFF),
    Colors.white,
    Color(0xFFFDE293),
  );

  void _paintMap(Canvas canvas, Size s, (Color, Color, Color, Color) colors) {
    final (bg, water, road, highway) = colors;
    canvas.drawRect(Offset.zero & s, Paint()..color = bg);
    canvas.drawPath(
      Path()
        ..moveTo(0, s.height * 0.7)
        ..quadraticBezierTo(
          s.width * 0.35,
          s.height * 0.6,
          s.width * 0.55,
          s.height,
        )
        ..lineTo(0, s.height)
        ..close(),
      Paint()..color = water,
    );
    final roadPaint = Paint()
      ..color = road
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(s.width * 0.25, 0),
      Offset(s.width * 0.5, s.height),
      roadPaint,
    );
    canvas.drawLine(
      Offset(0, s.height * 0.4),
      Offset(s.width, s.height * 0.25),
      roadPaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, s.height * 0.05)
        ..cubicTo(
          s.width * 0.5,
          s.height * 0.35,
          s.width * 0.6,
          s.height * 0.5,
          s.width,
          s.height * 0.8,
        ),
      Paint()
        ..color = highway
        ..strokeWidth = 6
        ..style = PaintingStyle.stroke,
    );
    final c = Offset(s.width * 0.66, s.height * 0.52);
    canvas.drawCircle(c, 6.5, Paint()..color = Colors.white);
    canvas.drawCircle(c, 5, Paint()..color = AppColors.camera);
  }

  @override
  void paint(Canvas canvas, Size s) {
    switch (look) {
      case MapLook.light:
        _paintMap(canvas, s, _lightColors);
      case MapLook.dark:
        _paintMap(canvas, s, _darkColors);
      case MapLook.standard:
        _paintMap(canvas, s, _googleColors);
      case MapLook.auto:
        // Half light, half dark, split diagonally.
        _paintMap(canvas, s, _lightColors);
        canvas.save();
        canvas.clipPath(
          Path()
            ..moveTo(s.width, 0)
            ..lineTo(s.width, s.height)
            ..lineTo(0, s.height)
            ..close(),
        );
        _paintMap(canvas, s, _darkColors);
        canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_MiniMapPainter old) => old.look != look;
}

/// Pick the sound for each warning (any audio file or a video's sound) and
/// how many times it plays.
class _SoundsSection extends StatelessWidget {
  const _SoundsSection({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    return _Group(
      title: 'Sound for each warning',
      footer:
          'Tap a warning to choose a built-in sound, any sound file, or a '
          'video (only its sound plays). Sounds stop after '
          '${maxClipLength.inSeconds} seconds. To give one place its own '
          'sound, tap that point on the map.',
      children: [
        _TypeSounds(app: app, type: PointType.camera),
        _TypeSounds(app: app, type: PointType.bump),
        _TypeSounds(app: app, type: PointType.mobile),
        _SwitchRow(
          icon: Icons.record_voice_over_rounded,
          color: const Color(0xFF0EA5E9),
          title: 'Say the distance too',
          subtitle: 'After a built-in sound: "Speed camera in 300 meters"',
          value: s.speakDistance,
          onChanged: (v) => app.updateSettings(s.copyWith(speakDistance: v)),
        ),
        _SlowDownSound(app: app),
      ],
    );
  }
}

/// Police radar (mobile speed cameras, police cars with a camera): found
/// automatically from drivers' sudden slowdowns.
class _RadarSection extends StatelessWidget {
  const _RadarSection({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = app.settings;
    return _Group(
      footer:
          'When you suddenly slow down on a fast road without stopping (like '
          'drivers do for a police radar), only that spot is sent, never your '
          'route. When several drivers slow down at the same new spot, every '
          'driver is warned. After you pass a police radar, tap "Still there" '
          'or "Not there" to keep the map right. Reports leave the map after '
          '${policeRadarLifetime.inHours} hours unless drivers confirm them.',
      children: [
        _SwitchRow(
          icon: Icons.local_police_rounded,
          color: p.radar,
          title: 'Find police radar automatically',
          subtitle: 'Share sudden slowdowns (no route, no name)',
          value: s.findRadar,
          onChanged: (v) => app.updateSettings(s.copyWith(findRadar: v)),
        ),
      ],
    );
  }
}

/// Opens the sound picker and saves the result for [slot]. With [toneType],
/// the picker also offers the built-in sounds for that warning type.
Future<void> _changeSound(
  BuildContext context,
  AppController app, {
  required String slot,
  required String title,
  required String resetLabel,
  PointType? toneType,
}) async {
  final s = app.settings;
  final hasOwn = app.sounds.has(s.sounds[slot]);
  final tone = toneType == null ? null : s.toneFor(toneType);
  final choice = await chooseSound(
    context,
    library: app.sounds,
    title: title,
    resetLabel: s.sounds.containsKey(slot) ? resetLabel : null,
    tones: toneType == null
        ? null
        : ToneOptions(
            selected: hasOwn ? null : tone,
            voiceSelected: !hasOwn && tone == null,
            defaultTone: WarningTone.defaultFor(toneType),
            onPlay: app.voice.previewTone,
          ),
  );
  switch (choice) {
    case PickedSound(:final sound):
      await app.setSound(slot, sound);
    case ResetSound():
      await app.setSound(slot, null);
    case ChosenTone(:final tone):
      // A built-in sound replaces your own file for this warning type.
      await app.updateSettings(
        app.settings.withSound(slot, null).withTone(toneType!, tone),
      );
    case null:
  }
}

class _TypeSounds extends StatefulWidget {
  const _TypeSounds({required this.app, required this.type});
  final AppController app;
  final PointType type;

  @override
  State<_TypeSounds> createState() => _TypeSoundsState();
}

class _TypeSoundsState extends State<_TypeSounds> {
  bool? _open;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final app = widget.app;
    final type = widget.type;
    final s = app.settings;
    final slot = SoundSlot.type(type);
    final own = s.sounds[slot];
    final distances = s.distancesFor(type);
    final repeat = s.repeatFor(slot);

    String defaultLabel() {
      final builtIn =
          app.voice.hasRecording(slot) ||
          distances.any(
            (d) => app.voice.hasRecording(SoundSlot.distance(type, d)),
          );
      return builtIn
          ? 'Built-in recordings'
          : describeTone(s.toneFor(type), speakDistance: s.speakDistance);
    }

    final perDistance = distances
        .where((d) => app.sounds.has(s.sounds[SoundSlot.distance(type, d)]))
        .length;
    final open = _open ?? perDistance > 0;

    return Column(
      children: [
        SoundRow(
          leading: PointTile(type: type),
          title: type.label,
          custom: app.sounds.has(own),
          subtitle: app.sounds.has(own)
              ? describeCustomSound(own!)
              : own != null
              ? 'File missing · ${defaultLabel()}'
              : defaultLabel(),
          onPlay: () => app.voice.previewSound(
            slots: [slot],
            text: '${type.label} in ${distances.first} meters.',
            repeat: repeat,
          ),
          onChange: () => _changeSound(
            context,
            app,
            slot: slot,
            title: '${type.label} sound',
            resetLabel: 'Remove my file',
            toneType: type,
          ),
        ),
        RepeatRow(value: repeat, onChanged: (v) => app.setRepeat(slot, v!)),
        InkWell(
          onTap: () => setState(() => _open = !open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(60, Space.md, Space.lg, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    perDistance == 0
                        ? 'Different sound for each distance'
                        : 'Different sound for each distance · $perDistance set',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: p.primary,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_more_rounded, color: p.primary),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !open
              ? const SizedBox(width: double.infinity)
              : Column(
                  children: [
                    for (final d in distances) ...[
                      const Divider(indent: 60),
                      _DistanceSound(app: app, type: type, meters: d),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _DistanceSound extends StatelessWidget {
  const _DistanceSound({
    required this.app,
    required this.type,
    required this.meters,
  });

  final AppController app;
  final PointType type;
  final int meters;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = app.settings;
    final slot = SoundSlot.distance(type, meters);
    final own = s.sounds[slot];
    final hasOwn = app.sounds.has(own);
    final slots = SoundSlot.forApproach(type, meters);
    final label = meters >= 1000 ? '${meters / 1000} km' : '$meters m';

    final String subtitle;
    if (hasOwn) {
      subtitle = describeCustomSound(own!);
    } else {
      final r = app.voice.resolve(slots);
      subtitle = r.origin == SoundOrigin.custom
          ? 'Same as all · ${describeCustomSound(r.custom!)}'
          : describeResolved(r);
    }

    return SoundRow(
      leading: IconTile(
        color: p.colorFor(type),
        soft: true,
        child: Text(
          meters >= 1000 ? '${meters ~/ 1000}k' : '$meters',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: p.colorFor(type),
          ),
        ),
      ),
      title: 'At $label',
      custom: hasOwn,
      subtitle: subtitle,
      onPlay: () => app.voice.previewSound(
        slots: slots,
        text: '${type.label} in $meters meters.',
        repeat: s.repeatFor(SoundSlot.type(type)),
      ),
      onChange: () => _changeSound(
        context,
        app,
        slot: slot,
        title: '${type.label} at $label',
        resetLabel: 'Same as all distances',
      ),
    );
  }
}

class _SlowDownSound extends StatelessWidget {
  const _SlowDownSound({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = app.settings;
    const slot = SoundSlot.overSpeed;
    final own = s.sounds[slot];
    final hasOwn = app.sounds.has(own);
    final repeat = s.repeatFor(slot);
    return Column(
      children: [
        SoundRow(
          leading: IconTile(color: p.danger, icon: Icons.speed_rounded),
          title: '"Slow down"',
          custom: hasOwn,
          subtitle: hasOwn
              ? describeCustomSound(own!)
              : describeResolved(app.voice.resolve(const [slot])),
          onPlay: () => app.voice.previewSound(
            slots: const [slot],
            text: 'Slow down!',
            repeat: repeat,
          ),
          onChange: () => _changeSound(
            context,
            app,
            slot: slot,
            title: '"Slow down" sound',
            resetLabel: 'Use the default sound',
          ),
        ),
        RepeatRow(value: repeat, onChanged: (v) => app.setRepeat(slot, v!)),
      ],
    );
  }
}

class _PointsSection extends StatelessWidget {
  const _PointsSection({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final cams = app.points.where((x) => x.type == PointType.camera).length;
    final bumps = app.points.where((x) => x.type == PointType.bump).length;
    final messenger = ScaffoldMessenger.of(context);
    final chevron = Icon(Icons.chevron_right_rounded, color: p.textTertiary);

    return _Group(
      children: [
        Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Row(
            children: [
              Expanded(
                child: _Stat(type: PointType.camera, count: cams),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: _Stat(type: PointType.bump, count: bumps),
              ),
            ],
          ),
        ),
        _Row(
          icon: Icons.content_paste_rounded,
          color: p.primary,
          title: 'Import from clipboard',
          subtitle: 'One per line: lat, lng, type, limit',
          trailing: chevron,
          onTap: () async {
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            try {
              final n = await app.importPoints(data?.text ?? '');
              messenger.showSnackBar(
                SnackBar(content: Text('Added $n new points')),
              );
            } on FormatException catch (e) {
              messenger.showSnackBar(
                SnackBar(
                  content: Text('Could not read the list: ${e.message}'),
                ),
              );
            }
          },
        ),
        _Row(
          icon: Icons.ios_share_rounded,
          color: p.success,
          title: 'Export to clipboard',
          subtitle: 'Back up or share your points',
          trailing: chevron,
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: app.exportAll()));
            messenger.showSnackBar(
              SnackBar(content: Text('Copied ${app.points.length} points')),
            );
          },
        ),
        _Row(
          icon: Icons.delete_outline_rounded,
          color: p.danger,
          title: 'Delete all points',
          titleColor: app.points.isEmpty ? p.textTertiary : p.danger,
          onTap: app.points.isEmpty
              ? null
              : () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Delete all points?'),
                      content: Text(
                        'This removes all ${app.points.length} points. '
                        'Export them first if you want a backup.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: p.danger,
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) await app.deleteAll();
                },
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.type, required this.count});
  final PointType type;
  final int count;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: p.softFor(type),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          PointTile(type: type, size: 36),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$count', style: numberStyle(24, color: p.text)),
                const SizedBox(height: 2),
                Text(
                  switch (type) {
                    PointType.camera => 'Cameras',
                    PointType.bump => 'Speed bumps',
                    PointType.mobile => 'Police radar',
                  },
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

// ---- Account & sync ---------------------------------------------------------

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${t.day}/${t.month}/${t.year}';
}

/// Backup status, sign in / out, and sharing.
class _AccountSection extends StatelessWidget {
  const _AccountSection({required this.app});
  final AppController app;

  Future<void> _credentials(BuildContext context, {required bool register}) {
    final sync = app.sync;
    return showDialog<void>(
      context: context,
      // Tapping outside must not close it in the middle of signing in.
      barrierDismissible: false,
      builder: (_) => _CredentialsDialog(
        register: register,
        email: sync.signedOutEmail,
        action: register ? sync.register : sync.signIn,
      ),
    );
  }

  Future<void> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String action,
    required Future<void> Function() run,
    bool danger = false,
  }) async {
    final p = context.palette;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(backgroundColor: p.danger)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await run();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = app.settings;
    final sync = app.sync;
    final account = sync.account;
    final registered = account != null && !account.isAnonymous;
    final signedOut = sync.signedOutEmail;

    final String status;
    if (sync.syncing) {
      status = 'Syncing…';
    } else if (sync.error != null) {
      status = sync.error!;
    } else if (sync.lastSyncAt case final at?) {
      final n = app.community.length;
      status =
          'Synced ${_ago(at)} · $n point${n == 1 ? '' : 's'} from other drivers';
    } else {
      status = 'Not synced yet';
    }
    final pending = sync.pending;

    return _Group(
      footer: registered
          ? 'Your points and settings are backed up to this account. '
                'Sound files stay on this phone.'
          : 'Back up with an email to keep your points and settings when you '
                'change phones. Other drivers never see your email.',
      children: [
        _Row(
          icon: sync.error != null
              ? Icons.cloud_off_rounded
              : Icons.cloud_done_outlined,
          color: sync.error != null ? p.warning : p.primary,
          title: account?.email ?? signedOut ?? 'This phone only',
          subtitle: pending > 0 && !sync.syncing
              ? '$status · $pending change${pending == 1 ? '' : 's'} to upload'
              : status,
          trailing: sync.syncing
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : IconButton(
                  tooltip: 'Sync now',
                  onPressed: sync.syncNow,
                  icon: Icon(Icons.sync_rounded, color: p.primary),
                ),
        ),
        if (!registered) ...[
          if (signedOut == null)
            _Row(
              icon: Icons.backup_outlined,
              color: p.success,
              title: 'Back up with email',
              subtitle: 'Create an account for your points',
              onTap: () => _credentials(context, register: true),
            ),
          _Row(
            icon: Icons.login_rounded,
            color: p.primary,
            title: signedOut != null
                ? 'Sign in again'
                : 'I already have an account',
            subtitle: 'Sign in to get your points back',
            onTap: () => _credentials(context, register: false),
          ),
        ] else ...[
          _Row(
            icon: Icons.logout_rounded,
            color: p.textSecondary,
            title: 'Sign out of this phone',
            onTap: () => _confirm(
              context,
              title: 'Sign out?',
              message:
                  'Your points stay in your account and are removed from this '
                  'phone. Sign in again to get them back.',
              action: 'Sign out',
              run: sync.signOut,
            ),
          ),
          _Row(
            icon: Icons.person_remove_outlined,
            color: p.danger,
            title: 'Delete account',
            titleColor: p.danger,
            onTap: () => _confirm(
              context,
              title: 'Delete your account?',
              message:
                  'Your account and backup are deleted from the server. '
                  'Points you shared stay on the map for other drivers, '
                  'without your name. Your points stay on this phone.',
              action: 'Delete',
              danger: true,
              run: sync.deleteAccount,
            ),
          ),
        ],
        _SwitchRow(
          icon: Icons.public_rounded,
          color: p.success,
          title: 'Share new points',
          subtitle: 'Drivers near them get warned too',
          value: s.sharePoints,
          onChanged: (v) => app.updateSettings(s.copyWith(sharePoints: v)),
        ),
      ],
    );
  }
}

/// Email + password, for creating an account or signing in.
class _CredentialsDialog extends StatefulWidget {
  const _CredentialsDialog({
    required this.register,
    required this.action,
    this.email,
  });

  final bool register;
  final String? email;
  final Future<void> Function(String email, String password) action;

  @override
  State<_CredentialsDialog> createState() => _CredentialsDialogState();
}

class _CredentialsDialogState extends State<_CredentialsDialog> {
  late final _email = TextEditingController(text: widget.email ?? '');
  final _password = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@')) {
      setState(() => _error = 'Enter your email address.');
      return;
    }
    if (widget.register && password.length < 8) {
      setState(() => _error = 'Use at least 8 characters for the password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.action(email, password);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // Fields with a visible box (the dialog and fields share a color).
    final field = InputDecoration(filled: true, fillColor: p.fill);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        // Scrolls when the keyboard leaves little room (small phones).
        scrollable: true,
        title: Text(widget.register ? 'Back up with email' : 'Sign in'),
        content: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.register
                    ? 'Your points and settings will be saved to this account.'
                    : 'Points you added on this phone move into the account.',
                style: TextStyle(fontSize: 14, color: p.textSecondary),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: _email,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                decoration: field.copyWith(hintText: 'Email'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: _hide,
                autofillHints: [
                  widget.register
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                ],
                onSubmitted: (_) => _submit(),
                decoration: field.copyWith(
                  hintText: widget.register
                      ? 'Password (at least 8 characters)'
                      : 'Password',
                  suffixIcon: IconButton(
                    tooltip: _hide ? 'Show password' : 'Hide password',
                    onPressed: () => setState(() => _hide = !_hide),
                    icon: Icon(
                      _hide
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: Space.sm),
                Text(_error!, style: TextStyle(color: p.danger, fontSize: 14)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.register ? 'Create account' : 'Sign in'),
          ),
        ],
      ),
    );
  }
}
