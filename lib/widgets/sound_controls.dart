import 'package:flutter/material.dart';

import '../models/custom_sound.dart';
import '../models/warning_tone.dart';
import '../services/sound_library.dart';
import '../services/sound_resolver.dart';
import '../theme/app_theme.dart';
import 'ui.dart';

/// What the user chose in [chooseSound].
sealed class SoundChoice {
  const SoundChoice();
}

/// A new file was picked and copied into the app.
class PickedSound extends SoundChoice {
  const PickedSound(this.sound);
  final CustomSound sound;
}

/// Go back to the default sound.
class ResetSound extends SoundChoice {
  const ResetSound();
}

/// A built-in sound was chosen ([tone] null: the phone voice only).
class ChosenTone extends SoundChoice {
  const ChosenTone(this.tone);
  final WarningTone? tone;
}

/// The built-in sounds offered by [chooseSound].
class ToneOptions {
  const ToneOptions({
    required this.selected,
    required this.voiceSelected,
    required this.defaultTone,
    required this.onPlay,
  });

  /// The tone with the check mark (null: none of them).
  final WarningTone? selected;

  /// "Phone voice only" has the check mark.
  final bool voiceSelected;

  /// Marked "default" in the list.
  final WarningTone defaultTone;

  /// Plays a tone without closing the sheet.
  final void Function(WarningTone tone) onPlay;
}

IconData _toneIcon(WarningTone t) => switch (t) {
  WarningTone.chime => Icons.notifications_rounded,
  WarningTone.alert => Icons.warning_amber_rounded,
  WarningTone.radar => Icons.radar_rounded,
  WarningTone.ding => Icons.notifications_none_rounded,
  WarningTone.bump => Icons.waves_rounded,
  WarningTone.doubleBeep => Icons.graphic_eq_rounded,
};

/// Asks where to get the sound from, opens the phone's picker and copies
/// the file. Returns null if the user cancelled or the file couldn't be
/// used (the reason is shown to the user). With [resetLabel], the sheet
/// also offers going back to the default sound. With [tones], it starts
/// with the built-in sounds (returned as [ChosenTone]).
Future<SoundChoice?> chooseSound(
  BuildContext context, {
  required SoundLibrary library,
  required String title,
  String? resetLabel,
  ToneOptions? tones,
}) async {
  final picked = await showAppSheet<Object>(
    context: context,
    isScrollControlled: tones != null,
    builder: (ctx) {
      final p = ctx.palette;
      Widget label(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, 0, Space.sm),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: p.textSecondary,
          ),
        ),
      );
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Space.xl,
          Space.sm,
          Space.xl,
          Space.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SheetHeader(
              title: title,
              subtitle: tones != null
                  ? 'A built-in sound, any audio file, or a video'
                  : 'Any audio file, or a video (only its sound plays)',
              onClose: () => Navigator.pop(ctx),
            ),
            if (tones != null) ...[
              label('Built-in sounds'),
              AppCard(
                child: Column(
                  children: [
                    for (final t in WarningTone.values) ...[
                      if (t != WarningTone.values.first)
                        const Divider(indent: 60),
                      _ToneOption(
                        icon: _toneIcon(t),
                        title: t.label,
                        subtitle: t == tones.defaultTone
                            ? '${t.description} · default'
                            : t.description,
                        selected: tones.selected == t,
                        onPlay: () => tones.onPlay(t),
                        onTap: () => Navigator.pop(ctx, ChosenTone(t)),
                      ),
                    ],
                    const Divider(indent: 60),
                    _ToneOption(
                      icon: Icons.record_voice_over_rounded,
                      title: 'Phone voice only',
                      subtitle: 'Says the distance, no sound before it',
                      selected: tones.voiceSelected,
                      onTap: () => Navigator.pop(ctx, const ChosenTone(null)),
                    ),
                  ],
                ),
              ),
              label('From your phone'),
            ] else
              const SizedBox(height: Space.lg),
            AppCard(
              child: Column(
                children: [
                  _SourceOption(
                    icon: Icons.folder_open_rounded,
                    color: p.primary,
                    title: 'Sound or any file',
                    subtitle: 'MP3, M4A, WAV, MP4, MOV… from your files',
                    onTap: () => Navigator.pop(ctx, SoundPickSource.files),
                  ),
                  const Divider(indent: 60),
                  _SourceOption(
                    icon: Icons.video_library_rounded,
                    color: const Color(0xFF8B5CF6),
                    title: 'Video from gallery',
                    subtitle: 'Uses the video\'s sound',
                    onTap: () => Navigator.pop(ctx, SoundPickSource.videos),
                  ),
                  if (resetLabel != null) ...[
                    const Divider(indent: 60),
                    _SourceOption(
                      icon: Icons.restart_alt_rounded,
                      color: p.textSecondary,
                      title: resetLabel,
                      onTap: () => Navigator.pop(ctx, const ResetSound()),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
  if (picked is ResetSound || picked is ChosenTone) return picked as SoundChoice;
  if (picked is! SoundPickSource || !context.mounted) return null;

  final navigator = Navigator.of(context);
  var loadingShown = false;
  void hideLoading() {
    if (loadingShown) navigator.pop();
    loadingShown = false;
  }

  try {
    final sound = await library.pick(
      picked,
      onCopying: () {
        if (!context.mounted) return;
        loadingShown = true;
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const PopScope(
            canPop: false,
            child: AlertDialog(
              content: Row(
                children: [
                  SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  SizedBox(width: Space.xl),
                  Text('Adding sound…'),
                ],
              ),
            ),
          ),
        );
      },
    );
    hideLoading();
    return sound == null ? null : PickedSound(sound);
  } on SoundImportException catch (e) {
    hideLoading();
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Can\'t use this file'),
          content: Text(e.message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    return null;
  }
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
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
              IconTile(color: color, icon: icon),
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
                        color: p.text,
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
              Icon(Icons.chevron_right_rounded, color: p.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// One built-in sound in [chooseSound]: tap to choose it, play to hear it.
class _ToneOption extends StatelessWidget {
  const _ToneOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.onPlay,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.sm,
            ),
            child: Row(
              children: [
                IconTile(color: p.primary, soft: true, icon: icon),
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
                          color: p.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 13, color: p.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (onPlay != null) ...[
                  const SizedBox(width: Space.sm),
                  PlayButton(onTap: onPlay!),
                ],
                const SizedBox(width: Space.sm),
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  color: selected ? p.primary : p.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "my_clip.mp4 · 0:03 · video sound".
String describeCustomSound(CustomSound s) => [
  s.name,
  if (s.duration case final d?) formatClipLength(d),
  if (s.isVideo) 'video sound',
  if ((s.duration ?? Duration.zero) > maxClipLength)
    'first ${maxClipLength.inSeconds} s',
].join(' · ');

/// What plays when nothing more specific is set, in a few words.
String describeResolved(ResolvedSound r) => switch (r.origin) {
  SoundOrigin.point || SoundOrigin.custom => describeCustomSound(r.custom!),
  SoundOrigin.builtIn => 'Built-in recording',
  SoundOrigin.tone => r.tone!.label,
  SoundOrigin.phoneVoice => 'Phone voice',
};

/// "Chime + voice", "Chime", or "Phone voice" (for [tone] null).
String describeTone(WarningTone? tone, {required bool speakDistance}) =>
    tone == null
    ? 'Phone voice'
    : speakDistance
    ? '${tone.label} + voice'
    : tone.label;

/// Round play button.
class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconButton(
      tooltip: 'Play',
      onPressed: onTap,
      style: IconButton.styleFrom(backgroundColor: p.primarySoft),
      icon: Icon(Icons.play_arrow_rounded, color: p.primary),
    );
  }
}

/// One warning sound: what plays, a play button, tap to change.
class SoundRow extends StatelessWidget {
  const SoundRow({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onPlay,
    required this.onChange,
    this.custom = false,
    this.padding = const EdgeInsets.symmetric(
      horizontal: Space.lg,
      vertical: Space.md,
    ),
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onPlay;
  final VoidCallback onChange;

  /// Highlights the subtitle when a sound of your own is set.
  final bool custom;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      onTap: onChange,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: padding,
          child: Row(
            children: [
              leading,
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
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (custom) ...[
                          Icon(
                            Icons.music_note_rounded,
                            size: 14,
                            color: p.primary,
                          ),
                          const SizedBox(width: 3),
                        ],
                        Expanded(
                          child: Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: custom ? p.primary : p.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.sm),
              PlayButton(onTap: onPlay),
              Icon(Icons.chevron_right_rounded, color: p.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// "1× 2× 3×…". With [defaultTimes] set, a first chip lets the value follow
/// the default (value null).
class RepeatChips extends StatelessWidget {
  const RepeatChips({
    super.key,
    required this.value,
    required this.onChanged,
    this.defaultTimes,
  });

  final int? value;
  final ValueChanged<int?> onChanged;
  final int? defaultTimes;

  @override
  Widget build(BuildContext context) {
    final options = <int?>[
      if (defaultTimes != null) null,
      for (var i = 1; i <= maxRepeat; i++) i,
    ];
    return Wrap(
      spacing: Space.sm,
      runSpacing: Space.sm,
      children: [
        for (final o in options)
          AppChip(
            label: o == null ? 'Default ($defaultTimes×)' : '$o×',
            selected: value == o,
            onTap: () => onChanged(o),
          ),
      ],
    );
  }
}

/// "Plays" label with the repeat chips, for under a [SoundRow].
class RepeatRow extends StatelessWidget {
  const RepeatRow({
    super.key,
    required this.value,
    required this.onChanged,
    this.defaultTimes,
    this.padding = const EdgeInsets.fromLTRB(60, 0, Space.lg, Space.lg),
  });

  final int? value;
  final ValueChanged<int?> onChanged;
  final int? defaultTimes;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Plays',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: Space.sm),
          RepeatChips(
            value: value,
            onChanged: onChanged,
            defaultTimes: defaultTimes,
          ),
        ],
      ),
    );
  }
}
