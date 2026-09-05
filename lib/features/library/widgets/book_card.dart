import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/offline/offline_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/cover_image.dart';
import '../../../models/abs_item.dart';

class BookCard extends ConsumerWidget {
  final AbsItem item;

  const BookCard({super.key, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider);
    final offlineBook = ref.watch(offlineStoreProvider).books[item.id];
    final coverUrl = item.coverUrl(config.absUrl);

    return GestureDetector(
      onTap: () => context.push('/book/${item.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppColors.cardRadius),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 8,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CoverImage(
                    url: coverUrl,
                    localPath: offlineBook?.coverPath,
                    httpHeaders: {
                      'Authorization': 'Bearer ${config.absToken}',
                    },
                    placeholder: _coverPlaceholder(),
                    iconSize: 40,
                  ),
                  if (offlineBook != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.offline_pin_rounded,
                          size: 14,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            item.author.isEmpty ? '—' : item.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: item.progress.clamp(0.0, 1.0),
              minHeight: 2,
              backgroundColor: AppColors.surfaceElevated,
              valueColor:
                  const AlwaysStoppedAnimation(AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder() => Container(
        color: AppColors.surface,
        child: const Center(
          child: Icon(Icons.menu_book_rounded,
              color: AppColors.surfaceElevated, size: 40),
        ),
      );
}
