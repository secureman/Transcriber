import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../player_provider.dart';

/// Thin pill-shaped scrubber + chapter/speed row (ElevenReader style).
class ChapterScrubber extends ConsumerWidget {
  const ChapterScrubber({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);

    final maxMs = player.chapterDuration.inMilliseconds;
    final value = player.position.inMilliseconds
        .clamp(0, maxMs == 0 ? 1 : maxMs)
        .toDouble();

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            thumbColor: AppColors.primary,
            activeTrackColor: AppColors.primary,
            inactiveTrackColor: AppColors.surfaceElevated,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: value,
            max: maxMs == 0 ? 1 : maxMs.toDouble(),
            onChanged: maxMs == 0
                ? null
                : (v) => notifier.seekTo(Duration(milliseconds: v.toInt())),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Text(
                '${player.position.mmss} / ${player.chapterDuration.mmss}',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
              const Spacer(),
              Text(
                'Chapter ${player.chapterIndex + 1}',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => notifier.cycleSpeed(),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_formatSpeed(player.speed)}×',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatSpeed(double speed) =>
      speed == speed.roundToDouble() ? speed.toStringAsFixed(1) : speed.toString();
}
