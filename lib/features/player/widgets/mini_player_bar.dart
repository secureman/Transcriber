import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/offline/offline_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../../../core/widgets/cover_image.dart';
import '../player_provider.dart';
import '../player_state.dart';

/// Compact bar shown at the bottom of the shell screens while something is
/// loaded in the player. Tap to reopen the full player; playback continues
/// because [playerProvider] is app-scoped.
class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final show = player.itemId != null;

    return SafeArea(
      top: false,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        reverseDuration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => SizeTransition(
          sizeFactor: animation,
          alignment: Alignment.topCenter,
          child: child,
        ),
        child: show
            ? _MiniBar(
                key: const ValueKey('mini-player'),
                player: player,
              )
            : const SizedBox.shrink(key: ValueKey('mini-player-hidden')),
      ),
    );
  }
}

class _MiniBar extends ConsumerWidget {
  final PlayerState player;

  const _MiniBar({super.key, required this.player});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemId = player.itemId!;
    final config = ref.watch(configProvider);
    final offlineBook = ref.watch(offlineStoreProvider).books[itemId];
    final meta = ref.watch(bookMetaProvider(itemId)).valueOrNull;
    final coverUrl = meta?.coverUrl(config.absUrl) ?? '';
    final notifier = ref.read(playerProvider.notifier);

    final progress = player.chapterDuration.inMilliseconds <= 0
        ? 0.0
        : (player.position.inMilliseconds /
                player.chapterDuration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble();

    return Material(
      color: AppColors.surface,
      child: InkWell(
        onTap: () => context.push('/player/$itemId/${player.chapterIndex}'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: AppColors.surfaceElevated,
              valueColor: const AlwaysStoppedAnimation(AppColors.primary),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 42,
                    height: 42,
                    child: CoverImage(
                      url: coverUrl,
                      localPath: offlineBook?.coverPath,
                      httpHeaders: {
                        'Authorization': 'Bearer ${config.absToken}',
                      },
                      radius: 8,
                      iconSize: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          meta?.title ??
                              (player.audioReady
                                  ? 'Audiobook'
                                  : 'Loading…'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Chapter ${player.chapterIndex + 1} · '
                          '${player.position.mmss} / '
                          '${player.chapterDuration.mmss}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      player.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    color: AppColors.textPrimary,
                    tooltip: player.playing ? 'Pause' : 'Play',
                    onPressed: player.audioReady
                        ? () => notifier.togglePlayPause()
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded),
                    color: AppColors.textPrimary,
                    tooltip: 'Next chapter',
                    onPressed:
                        player.isOnLastChapter || !player.audioReady
                            ? null
                            : () => notifier.nextChapter(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}