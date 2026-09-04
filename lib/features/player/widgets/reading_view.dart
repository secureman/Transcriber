import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/config_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../player_provider.dart';
import '../player_state.dart';

/// Renders the current cue's words as a wrapping RichText with the
/// highlighted (currently spoken) word inline — ElevenReader style.
class ReadingView extends ConsumerStatefulWidget {
  const ReadingView({super.key});

  @override
  ConsumerState<ReadingView> createState() => _ReadingViewState();
}

class _ReadingViewState extends ConsumerState<ReadingView> {
  final _scrollController = ScrollController();
  final _wordKeys = <int, GlobalKey>{};
  int? _lastHighlightedIndex;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);

    if (!player.hasVtt) {
      return _buildNotReady(player);
    }

    final cueIndex = player.currentCueIndex;
    if (cueIndex == null) {
      // Audio before first word — show first cue.
      return _buildCue(player, 0, null);
    }

    // Auto-scroll: center the highlighted word when it changes.
    final flatIndex = _flatIndexOf(player, cueIndex, player.currentWordIndex);
    if (flatIndex != null && flatIndex != _lastHighlightedIndex) {
      _lastHighlightedIndex = flatIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final key = _wordKeys[flatIndex];
        final ctx = key?.currentContext;
        if (ctx != null && mounted) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.5,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }

    return _buildCue(player, cueIndex, player.currentWordIndex);
  }

  int? _flatIndexOf(PlayerState player, int cueIndex, int? wordIndex) {
    if (wordIndex == null) return null;
    var count = 0;
    for (var i = 0; i < cueIndex && i < player.cues.length; i++) {
      count += player.cues[i].words.length;
    }
    return count + wordIndex;
  }

  Widget _buildCue(PlayerState player, int cueIndex, int? wordIndex) {
    final cue = player.cues[cueIndex];
    final baseStyle = AppTheme.readingStyle(size: player.readingFontSize);
    final highlightStyle = AppTheme.readingStyle(
      size: player.readingFontSize,
      bold: true,
    ).copyWith(color: AppColors.highlightText);
    final pastStyle = baseStyle.copyWith(
        color: baseStyle.color?.withValues(alpha: AppColors.pastWordOpacity));

    final spans = <InlineSpan>[];
    for (var wi = 0; wi < cue.words.length; wi++) {
      final word = cue.words[wi];
      final flatIdx = _flatIndexOf(player, cueIndex, wi);
      final isHighlighted = wi == wordIndex;
      final isPast = wordIndex != null && wi < wordIndex;

      TextStyle style;
      if (isHighlighted) {
        style = highlightStyle;
      } else if (isPast) {
        style = pastStyle;
      } else {
        style = baseStyle;
      }

      final span = WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          key: flatIdx != null ? (_wordKeys[flatIdx] ??= GlobalKey()) : null,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: isHighlighted
              ? const EdgeInsets.symmetric(horizontal: 5, vertical: 1)
              : EdgeInsets.zero,
          decoration: isHighlighted
              ? BoxDecoration(
                  color: AppColors.highlightBg,
                  borderRadius: BorderRadius.circular(4),
                )
              : null,
          child: Text(word.text, style: style),
        ),
      );
      spans.add(span);
      if (wi < cue.words.length - 1) {
        spans.add(const TextSpan(text: ' '));
      }
    }

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: RichText(
          textDirection:
              player.isArabic ? TextDirection.rtl : TextDirection.ltr,
          textAlign: player.isArabic ? TextAlign.right : TextAlign.left,
          text: TextSpan(children: spans),
        ),
      ),
    );
  }

  Widget _buildNotReady(PlayerState player) {
    if (player.vttStatus == VttStatus.transcribing) {
      final progress = player.transcribeProgress.clamp(0.0, 1.0);
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                "Transcribing this chapter…",
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: player.readingFontSize * 0.65,
                ),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 5,
                  backgroundColor: AppColors.surfaceElevated,
                  valueColor:
                      const AlwaysStoppedAnimation(AppColors.primary),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${(progress * 100).round()}%',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    final backendConfigured = ref.watch(configProvider).backendConfigured;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.graphic_eq,
              color: AppColors.textSecondary, size: 40),
          const SizedBox(height: 12),
          Text(
            "This chapter hasn't been transcribed yet",
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: player.readingFontSize * 0.7,
            ),
          ),
          if (backendConfigured) ...[
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () =>
                  ref.read(playerProvider.notifier).transcribeCurrentChapter(),
              child: const Text('TRANSCRIBE NOW'),
            ),
          ],
        ],
      ),
    );
  }
}
