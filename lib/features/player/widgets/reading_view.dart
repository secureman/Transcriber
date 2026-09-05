import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/providers/config_provider.dart';
import '../../../core/providers/reader_theme_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/vtt_cue.dart';
import '../player_provider.dart';
import '../player_state.dart';

class ReadingView extends ConsumerStatefulWidget {
  const ReadingView({super.key});

  @override
  ConsumerState<ReadingView> createState() => _ReadingViewState();
}

class _ReadingViewState extends ConsumerState<ReadingView> {
  final _scrollController = ScrollController();
  final _cueKeys = <int, GlobalKey>{};
  int? _lastScrolledCue;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(int ci) =>
      _cueKeys[ci] ??= GlobalKey(debugLabel: 'cue$ci');

  void _scrollToCue(int ci) {
    if (ci == _lastScrolledCue) return;
    _lastScrolledCue = ci;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _cueKeys[ci]?.currentContext;
      if (ctx != null && mounted) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.3,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final theme = ReaderThemeData.all[ref.watch(readerThemeProvider)]!;

    if (!player.hasVtt) return _notReady(player, theme);

    final cueIndex = player.currentCueIndex;
    if (cueIndex != null) _scrollToCue(cueIndex);

    // Single callback used by every word. The cue's children call this
    // with the timestamp of the tapped word.
    void onWordTap(Duration ts) {
      ref.read(playerProvider.notifier).seekTo(ts);
    }

    return ColoredBox(
      color: theme.background,
      child: Column(
        children: [
          if (player.servedFromCache) _CacheBanner(theme: theme),
          Expanded(
            child: ListView(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
              children: [
                for (var ci = 0; ci < player.cues.length; ci++)
                  _CueParagraph(
                    key: _keyFor(ci),
                    cue: player.cues[ci],
                    cueIndex: ci,
                    activeCueIndex: cueIndex,
                    activeWordIndex:
                        cueIndex == ci ? player.currentWordIndex : null,
                    fontSize: player.readingFontSize,
                    isArabic: player.isArabic,
                    theme: theme,
                    onWordTap: onWordTap,
                  ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _notReady(PlayerState player, ReaderThemeData theme) {
    if (player.vttStatus == VttStatus.transcribing) {
      final p = player.transcribeProgress.clamp(0.0, 1.0);
      return ColoredBox(
        color: theme.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: theme.highlightBg,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Transcribing…',
                  style: TextStyle(
                    color: theme.text.withValues(alpha: 0.6),
                    fontSize: player.readingFontSize * 0.65,
                  ),
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: p,
                    minHeight: 5,
                    backgroundColor: theme.surface,
                    valueColor: AlwaysStoppedAnimation(theme.highlightBg),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${(p * 100).round()}%',
                  style: TextStyle(
                    color: theme.text.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final hasBe = ref.watch(configProvider).backendConfigured;
    return ColoredBox(
      color: theme.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq,
                color: theme.text.withValues(alpha: 0.4), size: 40),
            const SizedBox(height: 12),
            Text(
              "This chapter hasn't been transcribed yet",
              style: TextStyle(
                color: theme.text.withValues(alpha: 0.6),
                fontSize: player.readingFontSize * 0.68,
              ),
              textAlign: TextAlign.center,
            ),
            if (hasBe) ...[
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.highlightBg,
                  foregroundColor: theme.highlightText,
                ),
                onPressed: () => ref
                    .read(playerProvider.notifier)
                    .transcribeCurrentChapter(),
                child: const Text('TRANSCRIBE NOW'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Offline cache banner ──────────────────────────────────────────────────

class _CacheBanner extends StatelessWidget {
  const _CacheBanner({required this.theme});
  final ReaderThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: theme.isDark
          ? Colors.white.withValues(alpha: 0.06)
          : Colors.black.withValues(alpha: 0.05),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off_rounded,
              size: 13, color: theme.text.withValues(alpha: 0.45)),
          const SizedBox(width: 6),
          Text(
            'Server offline · showing cached transcript',
            style: TextStyle(
              fontSize: 11,
              color: theme.text.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Cue paragraph (stable layout, reliable tap) ──────────────────────────
//
// One Text.rich per cue, with one TapGestureRecognizer per word.
// Layout doesn't shift when the active word changes (the highlighted
// word is rendered as a WidgetSpan inside the same Text.rich, so the
// line breaks and word positions stay put). Past words get a dim color
// via TextSpan.color; the active word gets a WidgetSpan with a
// background-color Container.

class _CueParagraph extends StatelessWidget {
  const _CueParagraph({
    super.key,
    required this.cue,
    required this.cueIndex,
    required this.activeCueIndex,
    required this.activeWordIndex,
    required this.fontSize,
    required this.isArabic,
    required this.theme,
    required this.onWordTap,
  });

  final VttCue cue;
  final int cueIndex;
  final int? activeCueIndex;
  final int? activeWordIndex;
  final double fontSize;
  final bool isArabic;
  final ReaderThemeData theme;
  final void Function(Duration) onWordTap;

  @override
  Widget build(BuildContext context) {
    final isCurrent = activeCueIndex == cueIndex;
    final isPastCue = activeCueIndex != null && cueIndex < activeCueIndex!;

    final baseStyle = GoogleFonts.lora(
      fontSize: fontSize,
      height: 1.85,
      color: theme.text,
      fontWeight: FontWeight.w400,
    );
    final dimStyle = baseStyle.copyWith(
      color: theme.text.withValues(alpha: theme.dimOpacity),
    );
    final activeTextStyle = GoogleFonts.lora(
      fontSize: fontSize,
      height: 1.85,
      color: theme.highlightText,
      fontWeight: FontWeight.w700,
    );

    // Build inline spans. A WidgetSpan for the active word so it gets
    // the amber pill background, TextSpan for everything else.
    final spans = <InlineSpan>[];
    for (var wi = 0; wi < cue.words.length; wi++) {
      final word = cue.words[wi];
      final isActive = isCurrent && wi == activeWordIndex;
      final isPastWord = isPastCue ||
          (isCurrent && activeWordIndex != null && wi < activeWordIndex!);

      if (isActive) {
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onWordTap(word.start),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.highlightBg,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(word.text, style: activeTextStyle),
            ),
          ),
        ));
      } else {
        spans.add(TextSpan(
          text: word.text,
          style: isPastWord ? dimStyle : baseStyle,
          recognizer: TapGestureRecognizer()..onTap = () => onWordTap(word.start),
        ));
      }

      // Inter-word space, except after the last word.
      if (wi < cue.words.length - 1) {
        spans.add(TextSpan(text: ' ', style: isPastWord ? dimStyle : baseStyle));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Text.rich(
        TextSpan(children: spans),
        textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
        textAlign: isArabic ? TextAlign.right : TextAlign.justify,
      ),
    );
  }
}
