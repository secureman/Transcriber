import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/config_provider.dart';
import '../../core/providers/shared_prefs_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/duration_ext.dart';
import '../../models/abs_item.dart';
import 'book_detail_provider.dart';
import 'widgets/chapter_list_tile.dart';
import 'widgets/transcribe_sheet.dart';

class BookDetailScreen extends ConsumerWidget {
  final String itemId;

  const BookDetailScreen({super.key, required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookAsync = ref.watch(bookDetailProvider(itemId));
    final jobsAsync = ref.watch(chapterStatusProvider(itemId));
    final activeJobsAsync = ref.watch(activeJobsProvider);

    return Scaffold(
      body: SafeArea(
        child: bookAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          ),
          error: (e, _) => Center(
            child: Text('Failed to load book\n$e',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary)),
          ),
          data: (book) {
            final config = ref.watch(configProvider);
            final prefs = ref.watch(sharedPrefsProvider);
            final lastPlayed = AppConfig.lastPlayedChapter(prefs, itemId) ?? 0;
            final statuses = jobsAsync.valueOrNull ?? const {};
            final active = activeJobsAsync.valueOrNull ?? const [];

            return RefreshIndicator(
              color: AppColors.primary,
              backgroundColor: AppColors.surface,
              onRefresh: () async {
                ref.invalidate(bookDetailProvider(itemId));
                ref.invalidate(chapterStatusProvider(itemId));
                ref.invalidate(activeJobsProvider);
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 88),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => context.pop(),
                    ),
                  ),
                  if (active.isNotEmpty) ...[
                    _ActiveJobsBanner(active: active, thisBookId: itemId),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Cover(book: book, config: config),
                      const SizedBox(width: 16),
                      Expanded(child: _Header(book: book)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => context.push('/player/$itemId/$lastPlayed'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 26),
                    label: const Text('READ ALONG'),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'Chapters',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Divider(height: 24),
                  ...List.generate(book.chapters.length, (i) {
                    final ch = book.chapters[i];
                    return ChapterListTile(
                      chapter: ch,
                      index: i,
                      job: statuses[i],
                      onTap: () => context.push('/player/$itemId/$i'),
                    );
                  }),
                ],
              ),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.highlightText,
        icon: const Icon(Icons.auto_awesome),
        label: const Text('Transcribe'),
        onPressed: () => _openTranscribeSheet(context, ref),
      ),
    );
  }

  void _openTranscribeSheet(BuildContext context, WidgetRef ref) {
    final book = ref.read(bookDetailProvider(itemId)).valueOrNull;
    if (book == null) return;

    // Transcription needs the optional backend server.
    if (!ref.read(configProvider).backendConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Transcription requires a transcription server. '
              'Add its URL in Setup to enable this feature.'),
        ),
      );
      return;
    }

    final prefs = ref.read(sharedPrefsProvider);
    final fromChapter = AppConfig.lastPlayedChapter(prefs, itemId) ?? 0;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => TranscribeSheet(
        itemId: itemId,
        totalChapters: book.chapters.length,
        fromChapter: fromChapter.clamp(0, book.chapters.length - 1),
      ),
    ).then((_) {
      // Kick off polling for job statuses right after starting.
      ref.invalidate(chapterStatusProvider(itemId));
    });
  }
}


class _Header extends StatelessWidget {
  final AbsItem book;

  const _Header({required this.book});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          book.title,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          book.author,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        const SizedBox(height: 6),
        Text(
          book.duration.asDuration.humanReadable,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      ],
    );
  }
}

class _ActiveJobsBanner extends StatelessWidget {
  final List<ActiveJob> active;
  final String thisBookId;

  const _ActiveJobsBanner({required this.active, required this.thisBookId});

  @override
  Widget build(BuildContext context) {
    // Highlight this book's own job first, then up to 2 others.
    final own = active.where((j) => j.bookId == thisBookId).toList();
    final others = active.where((j) => j.bookId != thisBookId).toList();
    final shown = [...own, ...others].take(3).toList();
    final overflow = active.length - shown.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Transcribing ${active.length} '
                  '${active.length == 1 ? "chapter" : "chapters"}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...shown.map((j) => _ActiveJobRow(job: j, isOwn: j.bookId == thisBookId)),
          if (overflow > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '+ $overflow more',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActiveJobRow extends StatelessWidget {
  final ActiveJob job;
  final bool isOwn;

  const _ActiveJobRow({required this.job, required this.isOwn});

  String _durationLabel() {
    if (job.durationSeconds < 60) return '${job.durationSeconds}s';
    final m = job.durationSeconds ~/ 60;
    final s = job.durationSeconds % 60;
    return s == 0 ? '${m}m' : '${m}m ${s}s';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  isOwn
                      ? 'Ch ${job.chapterIndex + 1}: ${job.chapterTitle}'
                      : '${job.bookTitle} — Ch ${job.chapterIndex + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isOwn ? AppColors.textPrimary : AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: isOwn ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              Text(
                '${job.progress.round()}% · ${_durationLabel()}',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: (job.progress / 100).clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: AppColors.surface,
              valueColor:
                  const AlwaysStoppedAnimation(AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}


class _Cover extends StatelessWidget {
  final AbsItem book;
  final AppConfig config;

  const _Cover({required this.book, required this.config});

  @override
  Widget build(BuildContext context) {
    final url = book.coverUrl(config.absUrl);
    return Container(
      width: 120,
      height: 180,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        boxShadow: const [
          BoxShadow(
              color: Colors.black54, blurRadius: 12, offset: Offset(0, 6)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        child: url.isEmpty
            ? Container(
                color: AppColors.surface,
                child: const Icon(Icons.menu_book_rounded,
                    color: AppColors.surfaceElevated, size: 40),
              )
            : CachedNetworkImage(
                imageUrl: url,
                httpHeaders: {'Authorization': 'Bearer ${config.absToken}'},
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => Container(
                  color: AppColors.surface,
                  child: const Icon(Icons.menu_book_rounded,
                      color: AppColors.surfaceElevated, size: 40),
                ),
              ),
      ),
    );
  }
}
