import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/config_provider.dart';
import '../../core/providers/reader_theme_provider.dart';
import '../../core/theme/app_theme.dart';
import 'player_provider.dart';
import 'player_state.dart';
import 'widgets/audio_controls.dart';
import 'widgets/chapter_scrubber.dart';
import 'widgets/reading_view.dart';
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

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(playerProvider.notifier)
          .init(widget.itemId, widget.chapterIndex);
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configProvider);
    final player = ref.watch(playerProvider);

    return Scaffold(
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
                colors: [
                  Colors.black.withValues(alpha: 0.85),
                  Colors.black,
                ],
              ),
            ),
          ),
          // 3. Foreground content.
          SafeArea(
            child: Column(
              children: [
                const _AppBar(),
                _HeaderInfo(itemId: widget.itemId, config: config),
                Expanded(
                  child: Consumer(
                    builder: (_, ref, __) {
                      final t = ReaderThemeData.all[
                          ref.watch(readerThemeProvider)]!;
                      return Container(
                        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: t.background,
                          borderRadius:
                              BorderRadius.circular(AppColors.cardRadius),
                        ),
                        child: const ReadingView(),
                      );
                    },
                  ),
                ),
                if (player.finished)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.check_circle,
                            color: AppColors.success, size: 18),
                        const SizedBox(width: 8),
                        const Text(
                          'End of book',
                          style: TextStyle(
                              color: AppColors.textPrimary, fontSize: 13),
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
                const AudioControls(),
                const SizedBox(height: 4),
                const ChapterScrubber(),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
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
    final url = meta?.coverUrl(config.absUrl) ?? '';
    if (url.isEmpty) {
      return Container(color: AppColors.background);
    }
    return Opacity(
      opacity: 0.15,
      child: CachedNetworkImage(
        imageUrl: url,
        httpHeaders: {'Authorization': 'Bearer ${config.absToken}'},
        fit: BoxFit.cover,
        imageBuilder: (context, imageProvider) => ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Image(image: imageProvider, fit: BoxFit.cover),
        ),
        errorWidget: (_, _, _) => Container(color: AppColors.background),
      ),
    );
  }
}

class _AppBar extends ConsumerWidget {
  const _AppBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        Expanded(
          child: Text(
            'Chapter ${player.chapterIndex + 1}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
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
    );
  }

  void _showOverflowMenu(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final selectedTheme =
        ref.watch(readerThemeProvider);

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
                    color: AppColors.surfaceElevated, width: 1),
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 12, height: 12,
                  decoration: BoxDecoration(
                    color: ReaderThemeData.all[selectedTheme]!.highlightBg,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              title: const Text('Reader theme',
                  style: TextStyle(
                      color: AppColors.textPrimary, fontSize: 14)),
              subtitle: Text(
                ReaderThemeData.all[selectedTheme]!.name,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right,
                  color: AppColors.textSecondary, size: 20),
              onTap: () {
                Navigator.of(context).pop();
                showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: AppColors.surface,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (_) => const ThemeSheet(),
                );
              },
            ),
            const Divider(height: 1),
            // ── Sleep timer
            const Padding(
              padding: EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Sleep timer',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 15),
                ),
              ),
            ),
            ...[
              (SleepTimerState.off, 'Off'),
              (SleepTimerState.min30, '30 minutes'),
              (SleepTimerState.min60, '60 minutes'),
              (SleepTimerState.endOfChapter, 'End of chapter'),
            ].map((e) => ListTile(
                  title: Text(e.$2,
                      style: const TextStyle(
                          color: AppColors.textPrimary, fontSize: 14)),
                  trailing: player.sleepTimer == e.$1
                      ? const Icon(Icons.check, color: AppColors.primary)
                      : null,
                  onTap: () {
                    notifier.setSleepTimer(e.$1);
                    Navigator.of(context).pop();
                  },
                )),
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
                      fontSize: 15),
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
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (_) => const ThemeSheet(),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Container(
            width: 24, height: 24,
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
              width: 10, height: 10,
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

class _HeaderInfo extends ConsumerWidget {
  final String itemId;
  final AppConfig config;

  const _HeaderInfo({required this.itemId, required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(bookMetaProvider(itemId)).valueOrNull;
    final url = meta?.coverUrl(config.absUrl) ?? '';

    return Column(
      children: [
        Container(
          width: 100,
          height: 140,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppColors.cardRadius),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black54, blurRadius: 12, offset: Offset(0, 6)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppColors.cardRadius),
            child: url.isEmpty
                ? Container(
                    color: AppColors.surface,
                    child: const Icon(Icons.menu_book_rounded,
                        color: AppColors.surfaceElevated, size: 36),
                  )
                : CachedNetworkImage(
                    imageUrl: url,
                    httpHeaders: {
                      'Authorization': 'Bearer ${config.absToken}',
                    },
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => Container(
                      color: AppColors.surface,
                      child: const Icon(Icons.menu_book_rounded,
                          color: AppColors.surfaceElevated, size: 36),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          meta?.title ?? '',
          style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          meta?.author ?? '',
          style:
              const TextStyle(color: AppColors.textSecondary, fontSize: 13),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
