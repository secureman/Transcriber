import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

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
  // scrollable_positioned_list instead of a plain ScrollController +
  // GlobalKey/ensureVisible: the old approach could only scroll to a cue
  // whose widget was still mounted (i.e. within the viewport + cache
  // extent). Scroll far enough away — in either direction — and the
  // target cue's Element gets discarded, so `_cueKeys[ci]?.currentContext`
  // came back null and the resync button silently did nothing. This
  // controller tracks index positions independently of what's currently
  // built, so `scrollTo`/`jumpTo` work reliably no matter how far away
  // the current scroll position is.
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  int? _lastScrolledCue;
  // True once the user has manually dragged the list away from wherever
  // auto-follow last put it. While true, auto-follow is suspended (so the
  // user can freely read ahead or back without being yanked away) and the
  // floating "jump back to playhead" button appears — same pattern as the
  // reference screenshot's floating action button, repurposed here for
  // something this app actually needs since it has no AI chat feature.
  bool _autoFollowSuspended = false;

  // ── End-of-chapter auto-scroll guards ──────────────────────────────
  // Near the end of a chapter the target cue's desired offset exceeds the
  // list's maxScrollExtent, so re-issuing scrollTo for every new cue just
  // re-animates toward an unreachable position — a jittery/stuttering loop
  // (worst in fullscreen, where the transcript owns the whole screen).
  // Three guards against that:
  //  * _atEnd — the list is already scrolled as far as it can go; later cue
  //    updates only advance the text highlight in place, with no scroll
  //    animation at all.
  //  * _autoScrollInFlight — never stack a second animation on top of an
  //    in-flight one; coalesce into _pendingScrollCue instead.
  //  * content changes/deep resyncs compare against _lastScrolledCue before
  //    scrolling, so identical targets never re-animate.
  bool _atEnd = false;
  bool _autoScrollInFlight = false;
  int? _pendingScrollCue;
  int _lastItemCount = -1;

  @override
  void initState() {
    super.initState();
    // Tracks the live scroll position so "already at the bottom" can be
    // detected even between rebuilds (ScrollablePositionedList notifies this
    // listener as the user drags / animations settle).
    _itemPositionsListener.itemPositions.addListener(_onItemPositionsChanged);
  }

  @override
  void dispose() {
    _itemPositionsListener.itemPositions.removeListener(
      _onItemPositionsChanged,
    );
    super.dispose();
  }

  /// Updates [_atEnd] from the live item positions. The list is considered
  /// fully scrolled when the last item (the trailing spacer at cueCount) is
  /// visibly at the bottom edge of the viewport.
  void _onItemPositionsChanged() {
    final itemCount = _lastItemCount;
    if (itemCount <= 0) return;
    var atEnd = false;
    for (final p in _itemPositionsListener.itemPositions.value) {
      if (p.index == itemCount - 1 && p.itemTrailingEdge >= 0.999) {
        atEnd = true;
        break;
      }
    }
    if (atEnd != _atEnd && mounted) setState(() => _atEnd = atEnd);
  }

  void _scrollToCue(int ci, {bool force = false}) {
    if (_autoFollowSuspended && !force) return;
    if (ci == _lastScrolledCue && !force) return;
    _lastScrolledCue = ci;
    if (!_itemScrollController.isAttached) return;
    // Already at the end of the list: the target is unreachable (its offset
    // is past maxScrollExtent), so skip the animation entirely — the
    // highlight still advances in place.
    if (_atEnd && !force) return;
    // Don't layer a second scroll animation on top of an in-flight one.
    // Coalesce into a single pending target instead, applied when the
    // current animation settles.
    if (_autoScrollInFlight) {
      _pendingScrollCue = ci;
      return;
    }
    _autoScrollInFlight = true;
    _itemScrollController
        .scrollTo(
          index: ci,
          alignment: 0.3,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          _autoScrollInFlight = false;
          if (!mounted) return;
          final pending = _pendingScrollCue;
          _pendingScrollCue = null;
          if (pending != null) _scrollToCue(pending);
          // Re-evaluate bottom state now that the animation settled — a
          // scroll ending at the bottom flips _atEnd so subsequent cue
          // updates stop re-animating.
          _onItemPositionsChanged();
        });
  }

  void _resync(int? cueIndex) {
    setState(() => _autoFollowSuspended = false);
    if (cueIndex != null) _scrollToCue(cueIndex, force: true);
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final theme = ReaderThemeData.all[ref.watch(readerThemeProvider)]!;

    if (!player.hasVtt) return _notReady(player, theme);

    final cueIndex = player.currentCueIndex;

    // New chapter / different transcript length → reset per-chapter
    // auto-scroll bookkeeping so the first cue re-centers cleanly and the
    // bottom-of-list flag doesn't leak in from the previous chapter.
    final itemCount = player.cues.length + 1;
    if (itemCount != _lastItemCount) {
      _lastItemCount = itemCount;
      _lastScrolledCue = null;
      _atEnd = false;
      _autoScrollInFlight = false;
      _pendingScrollCue = null;
    }

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
            // Brief fade-in when a new chapter's transcript arrives (or after
            // a fullscreen toggle re-layout) so the reset-to-top isn't an
            // abrupt cut — a cheap bonus layered on top of the auto-scroll
            // fix.
            child: TweenAnimationBuilder<double>(
              key: ValueKey('chapter-${player.chapterIndex}'),
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              builder: (context, opacity, child) =>
                  Opacity(opacity: opacity, child: child),
              child: Stack(
                children: [
                  // Fade the top and bottom edges of the reading area so text
                  // scrolls in/out smoothly instead of hard-clipping — matches
                  // the soft vignette in the reference screenshot.
                  ShaderMask(
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black,
                        Colors.black,
                        Colors.transparent,
                      ],
                      stops: [0.0, 0.06, 0.92, 1.0],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        // Only a real user drag suspends auto-follow — the
                        // programmatic scrollTo() from _scrollToCue must not
                        // trip this back on itself.
                        if (n is ScrollStartNotification &&
                            n.dragDetails != null &&
                            !_autoFollowSuspended) {
                          setState(() => _autoFollowSuspended = true);
                        }
                        return false;
                      },
                      child: ScrollablePositionedList.builder(
                        itemScrollController: _itemScrollController,
                        itemPositionsListener: _itemPositionsListener,
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.only(
                          // Fullscreen docks a slim vertical progress strip to
                          // the left edge — give the text room to clear it.
                          left: player.fullscreenReader ? 46 : 22,
                          right: 22,
                          top: 28,
                          bottom: 28,
                        ),
                        itemCount: player.cues.length + 1,
                        itemBuilder: (context, i) {
                          if (i == player.cues.length) {
                            return const SizedBox(height: 40);
                          }
                          return _CueParagraph(
                            key: ValueKey(i),
                            cue: player.cues[i],
                            cueIndex: i,
                            activeCueIndex: cueIndex,
                            activeWordIndex: cueIndex == i
                                ? player.currentWordIndex
                                : null,
                            fontSize: player.readingFontSize,
                            isArabic: player.isArabic,
                            theme: theme,
                            onWordTap: onWordTap,
                          );
                        },
                      ),
                    ),
                  ),
                  if (_autoFollowSuspended)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: _ResyncButton(
                        theme: theme,
                        onTap: () => _resync(cueIndex),
                      ),
                    ),
                ],
              ),
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
            Icon(
              Icons.graphic_eq,
              color: theme.text.withValues(alpha: 0.4),
              size: 40,
            ),
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

// ── Resync-to-playhead floating button ────────────────────────────────────

class _ResyncButton extends StatelessWidget {
  const _ResyncButton({required this.theme, required this.onTap});
  final ReaderThemeData theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: theme.isDark ? Colors.white : theme.text,
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Icon(
            Icons.center_focus_strong_rounded,
            color: theme.isDark ? Colors.black87 : theme.background,
            size: 22,
          ),
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
          Icon(
            Icons.wifi_off_rounded,
            size: 13,
            color: theme.text.withValues(alpha: 0.45),
          ),
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
//
// The currently-playing cue additionally sits inside a soft rounded
// gradient card (see _CueParagraph.build below) — the sentence-level
// highlight from the reference screenshot, layered on top of the
// existing per-word highlight rather than replacing it.

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

    final baseStyle = AppTheme.readingStyle(
      size: fontSize,
    ).copyWith(height: 1.85, color: theme.text);
    final dimStyle = baseStyle.copyWith(
      color: theme.text.withValues(alpha: theme.dimOpacity),
    );
    final activeTextStyle = AppTheme.readingStyle(
      size: fontSize,
      bold: true,
    ).copyWith(height: 1.85, color: theme.highlightText);

    // Build inline spans. A WidgetSpan for the active word so it gets
    // the amber pill background, TextSpan for everything else.
    final spans = <InlineSpan>[];
    for (var wi = 0; wi < cue.words.length; wi++) {
      final word = cue.words[wi];
      final isActive = isCurrent && wi == activeWordIndex;
      final isPastWord =
          isPastCue ||
          (isCurrent && activeWordIndex != null && wi < activeWordIndex!);

      if (isActive) {
        spans.add(
          WidgetSpan(
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
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: word.text,
            style: isPastWord ? dimStyle : baseStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => onWordTap(word.start),
          ),
        );
      }

      // Inter-word space, except after the last word.
      if (wi < cue.words.length - 1) {
        spans.add(
          TextSpan(text: ' ', style: isPastWord ? dimStyle : baseStyle),
        );
      }
    }

    final paragraph = Text.rich(
      TextSpan(children: spans),
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      textAlign: isArabic ? TextAlign.right : TextAlign.justify,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: isCurrent
          ? AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    theme.highlightBg.withValues(
                      alpha: theme.isDark ? 0.22 : 0.16,
                    ),
                    theme.highlightBg.withValues(
                      alpha: theme.isDark ? 0.06 : 0.05,
                    ),
                  ],
                ),
              ),
              child: paragraph,
            )
          : paragraph,
    );
  }
}
