import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/config_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/cover_image.dart';
import '../../../models/abs_item.dart';

/// Minimal book tile used in the home screen grid. Cover on top, title
/// + thin progress bar below — no author line, no listened badge, no
/// long-press affordances (those live on the detail screen).
class BookGridItem extends ConsumerWidget {
  final AbsItem item;

  const BookGridItem({super.key, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(configProvider);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/book/${item.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AspectRatio(
                aspectRatio: 1 / 1.5,
                child: CoverImage(
                  url: item.coverUrl(config.absUrl),
                  radius: 12,
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
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            _ProgressLine(progress: item.progress),
          ],
        ),
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  final double progress;
  const _ProgressLine({required this.progress});

  @override
  Widget build(BuildContext context) {
    if (progress <= 0) return const SizedBox(height: 3);
    return SizedBox(
      height: 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: progress.clamp(0.0, 1.0),
          backgroundColor: AppColors.surfaceElevated,
          valueColor: const AlwaysStoppedAnimation(AppColors.primary),
        ),
      ),
    );
  }
}