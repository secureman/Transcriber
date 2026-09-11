import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../player_provider.dart';
import '../player_state.dart';
import 'sleep_timer_sheet.dart';
import 'speed_sheet.dart';

/// Playback controls, two rows:
///
///  * primary — prev chapter · back 15s · big play/pause · forward 30s ·
///    next chapter (the podcast-style transport the approved plan calls
///    for; at the first chapter, prev restarts the current chapter from
///    the top, at the last chapter, next does nothing)
///  * secondary — sleep timer and the speed stepper, out of the way of
///    the thumb's main arc but still one tap deep.
class AudioControls extends ConsumerWidget {
  const AudioControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);

    final compact = MediaQuery.sizeOf(context).width < 360;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ChapterSkipButton(
                icon: Icons.skip_previous_rounded,
                onTap: player.chapterIndex > 0 || player.audioReady
                    ? () => notifier.prevChapter()
                    : null,
                tooltip: player.chapterIndex > 0
                    ? 'Previous chapter'
                    : 'Restart chapter',
              ),
              _SkipButton(
                icon: Icons.replay_rounded,
                label: '15',
                onTap: () => notifier.skipBackward15(),
                tooltip: 'Back 15s',
              ),
              const _PlayPauseButton(),
              _SkipButton(
                icon: Icons.forward_rounded,
                label: '30',
                onTap: () => notifier.skipForward30(),
                tooltip: 'Forward 30s',
              ),
              _ChapterSkipButton(
                icon: Icons.skip_next_rounded,
                onTap: player.isOnLastChapter
                    ? null
                    : () => notifier.nextChapter(),
                tooltip: player.isOnLastChapter
                    ? 'Last chapter'
                    : 'Next chapter',
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _SleepButton(active: player.sleepTimer != SleepTimerState.off),
              const _SpeedStepper(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Prev/next-chapter transport button: a filled round glyph like the
/// built-in skip icons, dimmed when the action is unavailable (next on the
/// last chapter).
class _ChapterSkipButton extends StatelessWidget {
  const _ChapterSkipButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 26,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 34,
            color: onTap == null
                ? AppColors.textSecondary.withValues(alpha: 0.4)
                : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _SleepButton extends StatelessWidget {
  const _SleepButton({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Sleep timer',
      child: IconButton(
        onPressed: () => showSleepTimerSheet(context),
        icon: Icon(
          active ? Icons.bedtime_rounded : Icons.bedtime_outlined,
          color: active ? AppColors.primary : AppColors.textPrimary,
        ),
        iconSize: 24,
      ),
    );
  }
}

/// Skip button styled like the reference: an outlined circular arrow icon
/// with the skip amount centered inside it, rather than Flutter's built-in
/// replay_15/forward_30 glyphs (which render the number quite small).
class _SkipButton extends StatelessWidget {
  const _SkipButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, size: 38, color: AppColors.textPrimary),
              Padding(
                // Nudge down slightly to sit in the visual center of the
                // arrow glyph (which curves mostly across the top half).
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayPauseButton extends ConsumerWidget {
  const _PlayPauseButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);

    return GestureDetector(
      // BUG FIX v2: taps are dead during the chapter-end rebuild (the queue
      // is being swapped underneath us) — disabling the button avoids a
      // pause/play racing the rebuild's own resume.
      onTap:
          player.audioReady && !player.advancing
              ? () => notifier.togglePlayPause()
              : null,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.textPrimary, width: 2),
        ),
        child: Center(
          child: !player.audioReady || player.advancing
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.textPrimary,
                  ),
                )
              // BUG FIX v2: a slow ABS fetch (just_audio refilling its
              // buffer) used to look identical to a frozen player — spin
              // the button while data is en route so it reads as loading.
              : player.buffering
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.textSecondary,
                      ),
                    )
                  : Icon(
                      player.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: AppColors.textPrimary,
                      size: 34,
                    ),
        ),
      ),
    );
  }
}

/// Playback speed stepper: a [−] / [+] pair around the speed label. The
/// label still opens the fine-control sheet on long-press (and cycles presets
/// on a plain tap); the buttons nudge the speed up/down by 0.1× without
/// leaving the control row.
class _SpeedStepper extends ConsumerWidget {
  const _SpeedStepper();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SpeedStepButton(
          icon: Icons.remove_rounded,
          tooltip: 'Slower',
          onPressed: () => notifier.adjustSpeed(-0.1),
        ),
        Tooltip(
          message: 'Tap to cycle, long-press for fine control',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => notifier.cycleSpeed(),
            onLongPress: () => showModalBottomSheet<void>(
              context: context,
              backgroundColor: AppColors.surface,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (_) => const SpeedSheet(),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                '${_formatSpeed(player.speed)}×',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        _SpeedStepButton(
          icon: Icons.add_rounded,
          tooltip: 'Faster',
          onPressed: () => notifier.adjustSpeed(0.1),
        ),
      ],
    );
  }

  String _formatSpeed(double speed) => speed == speed.roundToDouble()
      ? speed.toStringAsFixed(1)
      : speed.toString();
}

/// Compact circular-invisible speed nudge button, sized to fit the control
/// row without pushing the other buttons off narrow screens.
class _SpeedStepButton extends StatelessWidget {
  const _SpeedStepButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 22,
        child: SizedBox(
          width: 28,
          height: 40,
          child: Icon(icon, size: 20, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}
