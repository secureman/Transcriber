import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../player_provider.dart';
import '../player_state.dart';
import 'chapter_sheet.dart';


/// Chapter-name pill + two stacked scrubbers, Audiobookshelf-style: the top
/// slider + row track the whole audiobook, the bottom slider + row track
/// the current chapter. Both clocks show listening time, so both respect
/// playback speed.
class ChapterScrubber extends ConsumerWidget {
  const ChapterScrubber({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final meta = player.itemId == null
        ? null
        : ref.watch(bookMetaProvider(player.itemId!)).valueOrNull;
    final speed = player.speed;

    // -- Chapter-level (bottom) -----------------------------------------
    final chapterMaxMs = player.chapterDuration.inMilliseconds;
    final chapterValue = player.position.inMilliseconds
        .clamp(0, chapterMaxMs == 0 ? 1 : chapterMaxMs)
        .toDouble();
    final chapterElapsed = atPlaybackSpeed(
      player.position.isNegative ? Duration.zero : player.position,
      speed,
    );
    final chapterTotal = atPlaybackSpeed(player.chapterDuration, speed);
    final chapterRemaining = chapterTotal - chapterElapsed;

    // -- Book-level (top) -------------------------------------------------
    final bookMaxMs = (player.bookDurationSeconds * 1000).round();
    final elapsedInBookSeconds =
        player.chapterStartInBook + player.position.inMilliseconds / 1000.0;
    final bookValue = (elapsedInBookSeconds * 1000)
        .clamp(0, bookMaxMs == 0 ? 1 : bookMaxMs)
        .toDouble();
    final bookElapsed = atPlaybackSpeed(
      elapsedInBookSeconds.clamp(0, double.infinity).toDouble().asDuration,
      speed,
    );
    final bookTotal = atPlaybackSpeed(
      player.bookDurationSeconds.clamp(0, double.infinity).toDouble().asDuration,
      speed,
    );
    final bookRemaining = bookTotal - bookElapsed;
    final hasBookDuration = player.bookDurationSeconds > 0;

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
        const SizedBox(height: 2),
        // -- Top: whole-book scrubber ----------------------------------
        _ScrubberSlider(
          value: bookValue,
          max: bookMaxMs == 0 ? 1 : bookMaxMs.toDouble(),
          onChanged: (!hasBookDuration || meta == null || meta.chapters.isEmpty)
              ? null
              : (v) => notifier.seekToBookPosition(v / 1000.0),
        ),
        _TimeRow(
          label: 'Overall',
          elapsed: bookElapsed,
          remaining: bookRemaining.isNegative ? Duration.zero : bookRemaining,
          total: bookTotal,
        ),
        const SizedBox(height: 6),
        // -- Bottom: current-chapter scrubber ---------------------------
        _ScrubberSlider(
          value: chapterValue,
          max: chapterMaxMs == 0 ? 1 : chapterMaxMs.toDouble(),
          onChanged: chapterMaxMs == 0
              ? null
              : (v) => notifier.seekTo(Duration(milliseconds: v.toInt())),
        ),
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

/// Shared slider chrome for both the book-level and chapter-level scrubbers,
/// so the two read as a matched pair (like Audiobookshelf's stacked bars).
class _ScrubberSlider extends StatelessWidget {
  const _ScrubberSlider({
    required this.value,
    required this.max,
    required this.onChanged,
  });

  final double value;
  final double max;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbColor: AppColors.primary,
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: AppColors.surfaceElevated,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      ),
      child: Slider(
        value: value.clamp(0, max),
        max: max,
        onChanged: onChanged,
      ),
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
