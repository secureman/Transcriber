import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/offline/offline_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/providers/shared_prefs_provider.dart';
import '../../../core/providers/read_chapters_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../../../core/widgets/cover_image.dart';
import '../../../models/abs_item.dart';
import '../../player/player_state.dart';

/// Audiobookshelf-style compact library row: small cover on the left,
/// title / author / progress bar in the middle, speed-adjusted
/// "time left" on the right. Long-press toggles the book's "listened"
/// state, same affordance as the grid card.
class BookListTile extends ConsumerWidget {
  final AbsItem item;

  const BookListTile({super.key, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuild when the listened set changes so the badge stays live.
    ref.watch(readChaptersProvider);
    final chapterCount = item.chapters.length;

    // Speed-adjusted listening time left, ABS-style. Uses the last-used
    // playback speed (the same value the player restores) — there is no
    // per-book speed, so this is the best available estimate, and it falls
    // back to raw audio time at the 1.0 default.
    final lastSpeed =
        ref.watch(sharedPrefsProvider).getDouble(kPlaybackSpeedKey) ?? 1.0;
    final finished = item.progress >= 0.999;
    final remaining = finished || item.duration <= 0
        ? null
        : atPlaybackSpeed(
            ((1 - item.progress.clamp(0.0, 1.0)) * item.duration).asDuration,
            lastSpeed,
          );

    return _row(context, ref, chapterCount, finished, remaining);
  }

  Widget _row(
    BuildContext context,
    WidgetRef ref,
    int chapterCount,
    bool finished,
    Duration? remaining,
  ) {
    final config = ref.watch(configProvider);
    final offlineBook = ref.watch(offlineStoreProvider).books[item.id];
    final coverUrl = item.coverUrl(config.absUrl);
    final isBookListened = ref
        .read(readChaptersProvider.notifier)
        .isBookListened(item.id, chapterCount);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      onTap: () => context.push('/book/${item.id}'),
      onLongPress: () {
        HapticFeedback.mediumImpact();
        ref
            .read(readChaptersProvider.notifier)
            .toggleBookListened(item.id, chapterCount);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 2),
              content: Text(
                isBookListened
                    ? 'Marked "${item.title}" as not listened'
                    : 'Marked "${item.title}" as listened',
              ),
            ),
          );
      },
      leading: SizedBox(
        width: 52,
        height: 68,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CoverImage(
              url: coverUrl,
              localPath: offlineBook?.coverPath,
              httpHeaders: {'Authorization': 'Bearer ${config.absToken}'},
              iconSize: 22,
            ),
            if (offlineBook != null)
              Positioned(
                top: 2,
                right: 2,
                child: _badge(
                  const Icon(
                    Icons.offline_pin_rounded,
                    size: 10,
                    color: AppColors.primary,
                  ),
                ),
              ),
            if (isBookListened)
              Positioned(
                bottom: 2,
                right: 2,
                child: _badge(
                  const Icon(
                    Icons.headphones_rounded,
                    size: 10,
                    color: AppColors.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            item.author.isEmpty ? '—' : item.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: item.progress.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: AppColors.surfaceElevated,
              valueColor: const AlwaysStoppedAnimation(AppColors.primary),
            ),
          ),
        ],
      ),
      trailing: _trailing(finished, remaining),
    );
  }

  Widget _badge(Icon icon) => Container(
    padding: const EdgeInsets.all(2),
    decoration: const BoxDecoration(
      color: Colors.black54,
      shape: BoxShape.circle,
    ),
    child: icon,
  );

  /// Right-hand column: "5h 12m left" (speed-adjusted), "Finished" once
  /// ABS reports ~100% progress, or nothing when duration is unknown.
  Widget _trailing(bool finished, Duration? remaining) {
    if (finished) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, size: 13, color: AppColors.success),
          SizedBox(width: 4),
          Text(
            'Finished',
            style: TextStyle(
              color: AppColors.success,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }
    if (remaining == null) return const SizedBox.shrink();
    return Text(
      '${remaining.humanReadable} left',
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
    );
  }
}
