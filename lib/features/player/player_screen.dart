import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/offline/offline_provider.dart';
import '../../core/providers/config_provider.dart';
import '../../core/providers/reader_theme_provider.dart';
import '../../core/theme/app_theme.dart';
import 'player_provider.dart';
import 'player_state.dart';
import 'widgets/audio_controls.dart';
import 'widgets/chapter_scrubber.dart';
import 'widgets/player_accessory_row.dart';
import 'widgets/reading_view.dart';
import 'widgets/sleep_timer_sheet.dart';
import 'widgets/theme_sheet.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  final String itemId;
  final int chapterIndex;

  const PlayerScreen({
    super.key,
    required this.itemId,
    required this.chapterIndex,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(playerProvider.notifier)
          .init(widget.itemId, widget.chapterIndex);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Flush the reading/listening position whenever the app is backgrounded
    // or hidden — a killed Android process won't get a clean notifyFromDispose.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(ref.read(playerProvider.notifier).flushProgress());
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider);
    final player = ref.watch(playerProvider);
    final fullscreen = player.fullscreenReader;

    // Keep the system bars in sync with immersive mode. The select() makes
    // the listener fire only when the flag itself flips, not on every
    // playback position tick.
    ref.listen(playerProvider.select((s) => s.fullscreenReader), (_, on) {
      SystemChrome.setEnabledSystemUIMode(
        on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    });

    // Android back gesture/button: in fullscreen, back first leaves
    // fullscreen instead of popping the whole player.
    return PopScope(
      canPop: !fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && fullscreen) {
          ref.read(playerProvider.notifier).setFullscreenReader(false);
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Blurred cover background at low opacity.
            _BackgroundCover(itemId: widget.itemId, config: config),
            // 2. Dark gradient overlay.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withValues(alpha: 0.85), Colors.black],
                ),
              ),
            ),
            // 3. Foreground content.
            SafeArea(
              top: !fullscreen,
              child: Column(
                children: [
                  _AppBar(itemId: widget.itemId, fullscreen: fullscreen),
                  Expanded(child: _ReaderContainer(fullscreen: fullscreen)),
                  if (!fullscreen && player.finished)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.check_circle,
                            color: AppColors.success,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'End of book',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 16),
                          FilledButton.tonal(
                            onPressed: () =>
                                ref.read(playerProvider.notifier).restart(),
                            child: const Text('Restart'),
                          ),
                        ],
                      ),
                    ),
                  if (!fullscreen) ...[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: MediaQuery.sizeOf(context).width < 380
                            ? 8
                            : 16,
                      ),
                      child: const ChapterScrubber(),
                    ),
                    const SizedBox(height: 8),
                    const AudioControls(),
                    const SizedBox(height: 4),
                    const PlayerAccessoryRow(),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fullscreen chapter progress, shown as a slim vertical strip down the left
/// edge instead of a bottom bar.
///
/// A plain, dim bar: a thin rail with a short fill that grows from the top
/// down to the current progress position. Deliberately low-key — no glow, no
/// bright core. Drawn by a single [CustomPainter], with the playhead's
/// movement animated via [TweenAnimationBuilder] so seeks glide.
class _FullscreenProgressStrip extends ConsumerWidget {
  const _FullscreenProgressStrip({required this.theme});

  final ReaderThemeData theme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final durationMs = player.chapterDuration.inMilliseconds;
    final progress = durationMs <= 0
        ? 0.0
        : (player.position.inMilliseconds / durationMs).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;

        // Tap / drag anywhere on the strip to seek — the same scrubbing
        // interaction the old bottom progress bar offered, just vertical.
        void seekFrom(Offset local) {
          if (trackHeight <= 0 || player.chapterDuration == Duration.zero) {
            return;
          }
          final frac = (local.dy / trackHeight).clamp(0.0, 1.0).toDouble();
          notifier.seekTo(
            Duration(
              milliseconds: (player.chapterDuration.inMilliseconds * frac)
                  .round(),
            ),
          );
        }

        return Semantics(
          label: 'Chapter progress',
          value: '${(progress * 100).round()}%',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => seekFrom(d.localPosition),
            onVerticalDragStart: (d) => seekFrom(d.localPosition),
            onVerticalDragUpdate: (d) => seekFrom(d.localPosition),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: progress),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutSine,
              builder: (context, value, _) => CustomPaint(
                painter: _ProgressStripPainter(
                  progress: value.clamp(0.0, 1.0).toDouble(),
                  accent: theme.highlightBg,
                  track: theme.text.withValues(
                    alpha: theme.isDark ? 0.10 : 0.16,
                  ),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Paints the simple vertical progress strip: a dim full-height rail and a
/// slightly brighter (still dim) fill from the top down to the current
/// progress position.
class _ProgressStripPainter extends CustomPainter {
  _ProgressStripPainter({
    required this.progress,
    required this.accent,
    required this.track,
  });

  final double progress; // 0 (start) → 1 (end of chapter)
  final Color accent;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0) return;
    final centerX = size.width / 2;
    const width = 3.0;
    const radius = Radius.circular(1.5);

    // Dim rail spanning the fullscreen height — dimmer at both ends, a bit
    // brighter around the vertical middle.
    final rail = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(centerX, size.height / 2),
        width: width,
        height: size.height,
      ),
      radius,
    );
    canvas.save();
    canvas.clipRRect(rail, doAntiAlias: true);
    canvas.restore();
    canvas.drawRRect(rail, Paint()..color = track);

    // Progress fill from the top down to the current position. The lit band
    // is a gradient peaked at the strip's vertical middle and fading toward
    // the top and bottom ends — dimmer at the ends, a bit brighter in the
    // middle. Clip the fill to the rail so it never spills outside the strip.
    final fillH = (size.height * progress).clamp(0.0, size.height).toDouble();
    if (fillH <= 0) return;
    final lit = RRect.fromRectAndRadius(
      Rect.fromLTWH(centerX - width / 2, 0, width, fillH),
      radius,
    );
    canvas.save();
    canvas.clipRRect(lit, doAntiAlias: true);
    canvas.restore();
    canvas.drawRRect(
      lit,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.0, 0.45, 0.5, 0.55, 1.0],
          colors: [
            accent.withValues(alpha: 0.0),
            accent.withValues(alpha: 0.20),
            accent.withValues(alpha: 0.32),
            accent.withValues(alpha: 0.20),
            accent.withValues(alpha: 0.0),
          ],
        ).createShader(lit.outerRect),
    );
  }

  @override
  bool shouldRepaint(_ProgressStripPainter old) =>
      old.progress != progress || old.accent != accent || old.track != track;
}

class _ReaderContainer extends ConsumerWidget {
  final bool fullscreen;

  const _ReaderContainer({required this.fullscreen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ReaderThemeData.all[ref.watch(readerThemeProvider)]!;
    final Widget content;
    if (fullscreen) {
      // Fullscreen: the old bottom chapter bar is replaced by a slim
      // vertical progress strip docked to the left edge — it never
      // overlaps the read-along text (which pads further left in
      // fullscreen) and doesn't fight the system-back handling since it
      // sits inside the reader area.
      content = Stack(
        fit: StackFit.expand,
        children: [
          const ReadingView(),
          Positioned(
            top: 8,
            bottom: 8,
            left: 6,
            width: 26,
            child: _FullscreenProgressStrip(theme: t),
          ),
        ],
      );
    } else {
      content = const ReadingView();
    }
    return Container(
      margin: fullscreen
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(
              MediaQuery.sizeOf(context).width < 380 ? 10 : 16,
              8,
              MediaQuery.sizeOf(context).width < 380 ? 10 : 16,
              8,
            ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: fullscreen
            ? BorderRadius.zero
            : BorderRadius.circular(AppColors.cardRadius),
      ),
      child: content,
    );
  }
}

class _BackgroundCover extends ConsumerWidget {
  final String itemId;
  final AppConfig config;

  const _BackgroundCover({required this.itemId, required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(bookMetaProvider(itemId)).valueOrNull;
    final offlineBook = ref.watch(offlineStoreProvider).books[itemId];
    final url = meta?.coverUrl(config.absUrl) ?? '';

    ImageProvider? provider;
    final localCover = offlineBook?.coverPath;
    if (localCover != null && File(localCover).existsSync()) {
      provider = FileImage(File(localCover));
    } else if (url.isNotEmpty) {
      provider = CachedNetworkImageProvider(
        url,
        headers: {'Authorization': 'Bearer ${config.absToken}'},
      );
    }
    if (provider == null) return Container(color: AppColors.background);
    return Opacity(
      opacity: 0.15,
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Image(image: provider, fit: BoxFit.cover),
      ),
    );
  }
}

class _AppBar extends ConsumerWidget {
  final String itemId;
  final bool fullscreen;

  const _AppBar({required this.itemId, required this.fullscreen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(bookMetaProvider(itemId)).valueOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
            tooltip: 'Minimize',
            onPressed: () => context.pop(),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  meta?.title ?? 'Loading…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (meta?.author != null && meta!.author.isNotEmpty)
                  Text(
                    meta.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          // Immersive read-along toggle: expands the transcript over the
          // whole screen (hides the scrubber/controls and the system bars).
          // Tap again — or press Android back — to restore.
          IconButton(
            icon: Icon(
              fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
            ),
            tooltip: fullscreen ? 'Exit fullscreen' : 'Fullscreen read-along',
            onPressed: () => ref
                .read(playerProvider.notifier)
                .setFullscreenReader(!fullscreen),
          ),
          // Direct-access theme cycle button (long-press → open sheet).
          // Single tap cycles through themes so users don't have to
          // open the overflow menu just to change the look.
          _QuickThemeButton(),
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More options',
            onPressed: () => _showOverflowMenu(context, ref),
          ),
        ],
      ),
    );
  }

  void _showOverflowMenu(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final selectedTheme = ref.watch(readerThemeProvider);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Reader theme (now with a visible current-theme chip)
            ListTile(
              leading: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: ReaderThemeData.all[selectedTheme]!.swatch,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.surfaceElevated,
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: ReaderThemeData.all[selectedTheme]!.highlightBg,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              title: const Text(
                'Reader theme',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 14),
              ),
              subtitle: Text(
                ReaderThemeData.all[selectedTheme]!.name,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: AppColors.textSecondary,
                size: 20,
              ),
              onTap: () {
                Navigator.of(context).pop();
                showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: AppColors.surface,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  builder: (_) => const ThemeSheet(),
                );
              },
            ),
            const Divider(height: 1),
            // ── Sleep timer (shared sheet — see sleep_timer_sheet.dart;
            // also reachable directly from the moon icon in AudioControls)
            ListTile(
              leading: const Icon(
                Icons.bedtime_outlined,
                color: AppColors.textPrimary,
              ),
              title: const Text(
                'Sleep timer',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 14),
              ),
              subtitle: player.sleepTimer != SleepTimerState.off
                  ? Text(
                      switch (player.sleepTimer) {
                        SleepTimerState.min30 => '30 minutes',
                        SleepTimerState.min60 => '60 minutes',
                        SleepTimerState.endOfChapter => 'End of chapter',
                        SleepTimerState.off => '',
                      },
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    )
                  : null,
              trailing: const Icon(
                Icons.chevron_right,
                color: AppColors.textSecondary,
                size: 20,
              ),
              onTap: () {
                Navigator.of(context).pop();
                showSleepTimerSheet(context);
              },
            ),
            const Divider(),
            // ── Font size
            const Padding(
              padding: EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Font size',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  color: AppColors.textPrimary,
                  onPressed: () => notifier.changeFontSize(-2),
                ),
                Text(
                  player.readingFontSize.round().toString(),
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  color: AppColors.textPrimary,
                  onPressed: () => notifier.changeFontSize(2),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Quick theme cycle: tap to advance to the next theme, long-press to
/// open the full picker. Lives in the AppBar so users have a one-tap
/// path to changing the look without opening the overflow menu.
class _QuickThemeButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(readerThemeProvider);
    final data = ReaderThemeData.all[current]!;
    return Tooltip(
      message: 'Theme: ${data.name} (tap to cycle, long-press to pick)',
      child: GestureDetector(
        onTap: () {
          final values = ReaderThemeType.values;
          final next = values[(values.indexOf(current) + 1) % values.length];
          ref.read(readerThemeProvider.notifier).set(next);
        },
        onLongPress: () {
          showModalBottomSheet<void>(
            context: context,
            backgroundColor: AppColors.surface,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (_) => const ThemeSheet(),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: data.swatch,
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.textPrimary.withValues(alpha: 0.4),
                width: 1,
              ),
            ),
            alignment: Alignment.center,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: data.highlightBg,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
