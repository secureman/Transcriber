import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/offline/offline_provider.dart';
import '../../../core/providers/read_chapters_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../../../models/abs_item.dart';
import '../book_detail_provider.dart';

class ChapterListTile extends ConsumerWidget {
  final String itemId;
  final AbsChapter chapter;
  final int index;
  final ChapterJobStatus? job;
  final VoidCallback onTap;

  /// ino of the audio file containing this chapter (single file for
  /// single-file books). Empty when the book metadata has no mapping.
  final String audioIno;

  const ChapterListTile({
    super.key,
    required this.itemId,
    required this.chapter,
    required this.index,
    required this.job,
    required this.onTap,
    this.audioIno = '',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listenedSet = ref.watch(readChaptersProvider);
    final isListened = listenedSet.contains('$itemId/$index');

    // Per-chapter download state. Only shown for multi-file books where a
    // chapter maps 1:1 to its own file; single-file books download as a
    // whole from the main control.
    final store = ref.watch(offlineStoreProvider);
    final isMultiFile = store.bookFor(itemId) != null && audioIno.isNotEmpty;
    final dl = store.downloads[itemId];
    final chapterDownloaded = isMultiFile
        ? store.isChapterDownloaded(itemId, audioIno)
        : false;
    final chapterInFlight = isMultiFile &&
        dl != null &&
        dl.isRunning &&
        dl.currentIno == audioIno;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      onTap: onTap,
      title: Text(
        chapter.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TranscriptBadge(job: job),
            if (job?.isProcessing == true) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: (job?.progressFraction ?? 0).clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: AppColors.surfaceElevated,
                  valueColor:
                      const AlwaysStoppedAnimation(AppColors.primary),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${(job?.progress ?? 0).clamp(0, 100).round()}%',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 10),
              ),
            ],
            if (isListened) ...[
              const SizedBox(height: 4),
              _ListenedBadge(),
            ],
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isMultiFile) ...[
            _ChapterDownloadBadge(
              downloaded: chapterDownloaded,
              inFlight: chapterInFlight,
              onTap: chapterInFlight || chapterDownloaded
                  ? null
                  : () =>
                      ref
                          .read(offlineStoreProvider.notifier)
                          .downloadChapter(itemId, audioIno),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            chapter.duration.asDuration.mmss,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// Small circular indicator / download button at the end of a chapter row.
class _ChapterDownloadBadge extends StatelessWidget {
  final bool downloaded;
  final bool inFlight;
  final VoidCallback? onTap;

  const _ChapterDownloadBadge({
    required this.downloaded,
    required this.inFlight,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (inFlight) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: Padding(
          padding: EdgeInsets.all(3),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.primary,
          ),
        ),
      );
    }
    if (downloaded) {
      return const Icon(Icons.download_done_rounded,
          size: 22, color: AppColors.success);
    }
    return SizedBox(
      width: 22,
      height: 22,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 20,
        splashRadius: 16,
        onPressed: onTap,
        icon: const Icon(
          Icons.download_rounded,
          size: 20,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

// ── Transcript status badge (unchanged logic) ─────────────────────────────

class _TranscriptBadge extends StatelessWidget {
  final ChapterJobStatus? job;
  const _TranscriptBadge({required this.job});

  @override
  Widget build(BuildContext context) {
    switch (job?.status) {
      case ChapterJobStatus.done:
        return _pill(
          '✓ Ready',
          fg: AppColors.success,
          bg: AppColors.success.withValues(alpha: 0.12),
        );
      case ChapterJobStatus.processing:
        return const _ShimmerPill(text: '⋯ Transcribing');
      case ChapterJobStatus.pending:
        return _pill(
          '⋯ Queued',
          fg: AppColors.warning,
          bg: AppColors.warning.withValues(alpha: 0.12),
        );
      case ChapterJobStatus.error:
        return Tooltip(
          message: job?.errorMessage ?? 'Transcription failed',
          child: _pill(
            '⚠ Failed',
            fg: AppColors.error,
            bg: AppColors.error.withValues(alpha: 0.12),
          ),
        );
      default:
        return _pill(
          '○ Not transcribed',
          fg: AppColors.textSecondary,
          bg: AppColors.surfaceElevated,
        );
    }
  }

  Widget _pill(String text, {required Color fg, required Color bg}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          style:
              TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      );
}

// ── "Listened" badge — visually distinct from the green ✓ Ready ──────────

class _ListenedBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Amber pill with a headphone icon — different shape, colour, and icon
    // from the green ✓ Ready transcript badge.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.headphones_rounded,
              size: 11, color: AppColors.primary),
          const SizedBox(width: 4),
          Text(
            'Listened',
            style: TextStyle(
              color: AppColors.primary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shimmer pill (unchanged) ───────────────────────────────────────────────

class _ShimmerPill extends StatefulWidget {
  final String text;
  const _ShimmerPill({required this.text});

  @override
  State<_ShimmerPill> createState() => _ShimmerPillState();
}

class _ShimmerPillState extends State<_ShimmerPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.45, end: 1.0).animate(_c),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            widget.text,
            style: const TextStyle(
              color: AppColors.warning,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}
