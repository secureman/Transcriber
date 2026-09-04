import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../player_provider.dart';

class AudioControls extends ConsumerWidget {
  const AudioControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          onPressed: () => ref.read(playerProvider.notifier).skipBackward15(),
          icon: const Icon(Icons.replay_10_rounded),
          iconSize: 30,
          color: AppColors.textPrimary,
          tooltip: 'Back 15s',
        ),
        IconButton(
          onPressed:
              player.chapterIndex > 0 ? () => ref.read(playerProvider.notifier).prevChapter() : null,
          icon: const Icon(Icons.skip_previous_rounded),
          iconSize: 32,
          color: AppColors.textPrimary,
          tooltip: 'Previous chapter',
        ),
        _PlayPauseButton(playing: player.playing),
        IconButton(
          onPressed:
              player.audioReady ? () => ref.read(playerProvider.notifier).nextChapter() : null,
          icon: const Icon(Icons.skip_next_rounded),
          iconSize: 32,
          color: AppColors.textPrimary,
          tooltip: 'Next chapter',
        ),
        IconButton(
          onPressed: () => ref.read(playerProvider.notifier).skipForward15(),
          icon: const Icon(Icons.forward_10_rounded),
          iconSize: 30,
          color: AppColors.textPrimary,
          tooltip: 'Forward 15s',
        ),
      ],
    );
  }
}

class _PlayPauseButton extends ConsumerWidget {
  final bool playing;

  const _PlayPauseButton({required this.playing});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);

    return GestureDetector(
      onTap:
          player.audioReady ? () => ref.read(playerProvider.notifier).togglePlayPause() : null,
      child: Container(
        width: 56,
        height: 56,
        decoration: const BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Icon(
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: AppColors.highlightText,
          size: 34,
        ),
      ),
    );
  }
}
