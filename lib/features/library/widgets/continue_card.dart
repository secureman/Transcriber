import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/config_provider.dart';
import '../../../core/providers/last_played_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../../../core/widgets/cover_image.dart';
import '../../../core/widgets/primary_button.dart';
import '../../../models/abs_item.dart';

/// Primary "Resume" card on the home screen. Surfaces the most recently
/// played book with its cover, progress, and one-tap Resume / Read
/// actions. Hidden by the parent when there's nothing resumable.
class ContinueCard extends ConsumerWidget {
  final LastPlayed lastPlayed;

  const ContinueCard({super.key, required this.lastPlayed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = lastPlayed.item;
    final config = ref.watch(configProvider);

    final progressFraction = _progressFraction(item);
    final timeLeft = _formatTimeLeft(item);

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openPlayer(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 84,
                    height: 120,
                    child: CoverImage(
                      url: item.coverUrl(config.absUrl),
                      radius: 12,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Continue listening',
                          style: TextStyle(
                            color: AppColors.primary.withValues(alpha: 0.9),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progressFraction,
                  minHeight: 4,
                  backgroundColor: AppColors.surfaceElevated,
                  valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    timeLeft,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '${(progressFraction * 100).round()}%',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: PrimaryButton(
                      loading: false,
                      onPressed: () => _openPlayer(context),
                      label: 'Resume',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => context.push('/book/${item.id}'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        foregroundColor: AppColors.textPrimary,
                        side: BorderSide(
                          color: AppColors.surfaceElevated,
                          width: 1,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                      child: const Text('Read'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openPlayer(BuildContext context) {
    final chapterIndex = lastPlayed.progress.chapterIndex;
    context.push('/player/${lastPlayed.item.id}/$chapterIndex');
  }

  /// Prefer the server-reported fraction (already merged in by the library
  /// provider from `/api/me`'s mediaProgress); fall back to local
  /// whole-book position when the server hasn't reported progress yet.
  double _progressFraction(AbsItem item) {
    if (item.progress > 0) return item.progress.clamp(0.0, 1.0);
    final total = item.duration;
    if (total <= 0) return 0;
    return (lastPlayed.wholeBookSeconds / total).clamp(0.0, 1.0);
  }

  String _formatTimeLeft(AbsItem item) {
    final total = item.duration;
    if (total <= 0) return '—';
    final position = item.resumeSeconds ?? lastPlayed.wholeBookSeconds;
    final remaining = (total - position).clamp(0.0, total);
    if (remaining <= 0) return 'Finished';
    return '${Duration(seconds: remaining.round()).humanReadable} left';
  }
}