import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/offline/offline_provider.dart';
import '../../../core/theme/app_theme.dart';

/// Download / progress / remove control shown on the book detail screen.
class DownloadControl extends ConsumerWidget {
  final String itemId;

  /// Total number of audio files the book has (from the item metadata).
  /// 0 when unknown — the card then behaves like before (no partial state).
  final int totalFileCount;

  const DownloadControl({
    super.key,
    required this.itemId,
    this.totalFileCount = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(offlineStoreProvider);
    final book = store.books[itemId];
    final progress = store.downloads[itemId];
    final notifier = ref.read(offlineStoreProvider.notifier);

    if (progress != null && progress.isRunning) {
      return _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.download_for_offline_outlined,
                    color: AppColors.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Downloading… ${(progress.fraction * 100).round()}%',
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () => notifier.cancel(itemId),
                  child: const Text('Cancel'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 4,
                backgroundColor: AppColors.surfaceElevated,
                valueColor: const AlwaysStoppedAnimation(AppColors.primary),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              progress.totalFiles > 1
                  ? '${progress.completedFiles} of ${progress.totalFiles} files downloaded'
                  : 'Downloading chapter…',
              style:
                  const TextStyle(color: AppColors.textSecondary, fontSize: 11),
            ),
          ],
        ),
      );
    }

    if (progress != null && !progress.isRunning) {
      // Failed / cancelled download.
      return _Card(
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: AppColors.error, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                progress.error ?? 'Download failed',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.error, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () => notifier.dismissError(itemId),
              child: const Text('Dismiss'),
            ),
            TextButton(
              onPressed: () => notifier.download(itemId),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (book != null) {
      // Fully downloaded -> green check; partial (chapter-level or resumed
      // download) -> show what is on device and offer to fetch the rest.
      final totalFiles = totalFileCount;
      final haveCount = store.downloadedChapterCount(itemId);
      final complete = totalFiles <= 1 || haveCount >= totalFiles;
      return _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  complete
                      ? Icons.offline_pin_rounded
                      : Icons.offline_pin_outlined,
                  color: complete ? AppColors.primary : AppColors.warning,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        complete ? 'Available offline' : 'Partially offline',
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        totalFiles > 1
                            ? '$haveCount of $totalFiles chapters on device '
                                '· ${_fmtSize(book.sizeBytes)}'
                            : '${_fmtSize(book.sizeBytes)} · plays without a server',
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => notifier.remove(itemId),
                  child: const Text('Remove'),
                ),
              ],
            ),
            if (!complete) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: totalFiles > 0 ? haveCount / totalFiles : null,
                  minHeight: 3,
                  backgroundColor: AppColors.surfaceElevated,
                  valueColor: const AlwaysStoppedAnimation(AppColors.warning),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: progress != null
                      ? null
                      : () => notifier.download(itemId),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download remaining'),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return FilledButton.tonalIcon(
      onPressed: () => notifier.download(itemId),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      icon: const Icon(Icons.download_for_offline_outlined),
      label: const Text('Download for offline'),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: child,
    );
  }
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}