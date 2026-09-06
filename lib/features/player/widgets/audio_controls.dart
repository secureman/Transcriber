import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../player_provider.dart';
import '../player_state.dart';
import 'sleep_timer_sheet.dart';
import 'speed_sheet.dart';

/// Playback control row, redesigned to match the reference screenshot:
/// sleep timer — 15s back — big outlined play/pause — 30s forward — speed.
/// Chapter prev/next now live in the chapter list sheet (see chapter_sheet.dart)
/// rather than in this row, matching the reference layout, which has no
/// prev/next-chapter buttons here at all.
class AudioControls extends ConsumerWidget {
  const AudioControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _SleepButton(active: player.sleepTimer != SleepTimerState.off),
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
          const _SpeedChip(),
        ],
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
      onTap: player.audioReady ? () => notifier.togglePlayPause() : null,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.textPrimary, width: 2),
        ),
        child: Center(
          child: !player.audioReady
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.textPrimary,
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

class _SpeedChip extends ConsumerWidget {
  const _SpeedChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);

    return Tooltip(
      message: 'Tap to cycle, long-press for fine control',
      child: GestureDetector(
        onTap: () => notifier.cycleSpeed(),
        onLongPress: () => showModalBottomSheet<void>(
          context: context,
          backgroundColor: AppColors.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (_) => const SpeedSheet(),
        ),
        child: Text(
          '${_formatSpeed(player.speed)}×',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  String _formatSpeed(double speed) =>
      speed == speed.roundToDouble() ? speed.toStringAsFixed(1) : speed.toString();
}
