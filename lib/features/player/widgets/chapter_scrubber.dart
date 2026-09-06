import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../player_provider.dart';
import '../player_state.dart';
import 'chapter_sheet.dart';

/// Chapter-name pill + scrubber + three-label time row (ElevenReader style):
/// elapsed-in-book on the left, time-left-in-book in the center, time-left
/// in the current chapter on the right.
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

    final elapsedInBook =
        (player.chapterStartInBook + player.position.inMilliseconds / 1000.0)
            .asDuration;
    final leftInBook = (player.bookDurationSeconds -
            player.chapterStartInBook -
            player.position.inMilliseconds / 1000.0)
        .clamp(0, double.infinity)
        .toDouble()
        .asDuration;
    final leftInChapter =
        (player.chapterDuration - player.position).isNegative
            ? Duration.zero
            : player.chapterDuration - player.position;

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
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.7,
                ),
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                elapsedInBook.mmss,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
              if (player.bookDurationSeconds > 0)
                Text(
                  '${leftInBook.humanReadable} left',
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
              Text(
                leftInChapter.mmss,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
