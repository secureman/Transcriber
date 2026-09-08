import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../player_provider.dart';
import '../player_state.dart';
import 'chapter_sheet.dart';


/// Chapter-name pill + scrubber + Audiobookshelf-style time rows.
/// The first row is the whole-book clock and the second is the current chapter
/// clock. Both clocks show listening time, so they respect playback speed.
class ChapterScrubber extends ConsumerWidget {
  const ChapterScrubber({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final meta = player.itemId == null
        ? null
        : ref.watch(bookMetaProvider(player.itemId!)).valueOrNull;
    final maxMs = player.chapterDuration.inMilliseconds;
    final value = player.position.inMilliseconds
        .clamp(0, maxMs == 0 ? 1 : maxMs)
        .toDouble();
    final speed = player.speed;
    final bookElapsed = atPlaybackSpeed(
      (player.chapterStartInBook + player.position.inMilliseconds / 1000.0)
          .clamp(0, double.infinity)
          .toDouble()
          .asDuration,
      speed,
    );
    final bookTotal = atPlaybackSpeed(
      player.bookDurationSeconds.clamp(0, double.infinity).toDouble().asDuration,
      speed,
    );
    final bookRemaining = bookTotal - bookElapsed;
    final chapterElapsed = atPlaybackSpeed(
      player.position.isNegative ? Duration.zero : player.position,
      speed,
    );
    final chapterTotal = atPlaybackSpeed(player.chapterDuration, speed);
    final chapterRemaining = chapterTotal - chapterElapsed;
    final chapterTitle = (meta != null &&
            player.chapterIndex >= 0 &&
            player.chapterIndex < meta.chapters.length)
        ? meta.chapters[player.chapterIndex].title
        : 'Chapter ${player.chapterIndex + 1}';

    return Column(
      children: [
        GestureDetector(
          onTap: () => showModalBottomSheet<void>(
            context: context,
            backgroundColor: AppColors.surface,
            isScrollControlled: true,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            builder: (_) => const ChapterSheet(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.menu_rounded,
                  size: 15, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
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
        _TimeRow(
          label: 'Overall',
          elapsed: bookElapsed,
          remaining: bookRemaining.isNegative ? Duration.zero : bookRemaining,
          total: bookTotal,
        ),
        const SizedBox(height: 3),
        _TimeRow(
          label: 'Chapter',
          elapsed: chapterElapsed,
          remaining:
              chapterRemaining.isNegative ? Duration.zero : chapterRemaining,
          total: chapterTotal,
        ),
      ],
    );
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.label,
    required this.elapsed,
    required this.remaining,
    required this.total,
  });

  final String label;
  final Duration elapsed;
  final Duration remaining;
  final Duration total;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: AppColors.textSecondary,
      fontSize: MediaQuery.sizeOf(context).width < 360 ? 11 : 12,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          SizedBox(width: 58, child: Text(label, style: style)),
          Text(elapsed.mmss, style: style),
          const Spacer(),
          Text('-${remaining.mmss}', style: style),
          const SizedBox(width: 5),
          Text('/ ${total.mmss}', style: style),
        ],
      ),
    );
  }
}
