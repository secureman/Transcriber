import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../player_provider.dart';
import '../player_state.dart';

/// Lightweight chapter-jump sheet for the player itself. Unlike
/// [ChapterListTile] on the book detail screen (which also surfaces
/// transcript/download state), this is just "where am I, where can I go" —
/// title, duration, and a highlight on the currently-playing chapter.
class ChapterSheet extends ConsumerWidget {
  const ChapterSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final itemId = player.itemId;
    final meta = itemId == null
        ? null
        : ref.watch(bookMetaProvider(itemId)).valueOrNull;
    final chapters = meta?.chapters ?? const [];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                'Chapters',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (chapters.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'Chapter list unavailable',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: chapters.length,
                  itemBuilder: (context, i) {
                    final isCurrent = i == player.chapterIndex;
                    return _ChapterRow(
                      index: i,
                      title: chapters[i].title,
                      duration: chapters[i].duration.asDuration,
                      isCurrent: isCurrent,
                      onTap: () {
                        Navigator.of(context).pop();
                        if (!isCurrent) {
                          ref
                              .read(playerProvider.notifier)
                              .switchChapter(i);
                        }
                      },
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.index,
    required this.title,
    required this.duration,
    required this.isCurrent,
    required this.onTap,
  });

  final int index;
  final String title;
  final Duration duration;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: isCurrent
                  ? const Icon(Icons.graphic_eq_rounded,
                      size: 18, color: AppColors.primary)
                  : Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isCurrent
                      ? AppColors.primary
                      : AppColors.textPrimary,
                  fontSize: 14.5,
                  fontWeight:
                      isCurrent ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              duration.mmss,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
