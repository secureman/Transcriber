import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/shared_prefs_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/duration_ext.dart';
import '../player_provider.dart';
import '../player_state.dart';

const _bookmarksPrefsKey = 'chapter_bookmarks_v1';

/// Bottom accessory row: narrator info (non-interactive — this app plays
/// real audiobook narration from ABS, not a selectable synthesized voice,
/// so unlike the reference screenshot's tappable voice picker, this is
/// just a label) and a bookmark button that saves the exact whole-book
/// position under a per-book list in SharedPreferences.
class PlayerAccessoryRow extends ConsumerWidget {
  const PlayerAccessoryRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final meta = player.itemId == null
        ? null
        : ref.watch(bookMetaProvider(player.itemId!)).valueOrNull;
    final narrator = meta?.narratorName;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const SizedBox(width: 40), // balances the bookmark button's width
          if (narrator != null && narrator.isNotEmpty)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.mic_none_rounded,
                      size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    narrator,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            )
          else
            const SizedBox.shrink(),
          _BookmarkButton(itemId: player.itemId),
        ],
      ),
    );
  }
}

class _BookmarkButton extends ConsumerWidget {
  const _BookmarkButton({required this.itemId});
  final String? itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Tooltip(
      message: 'Add bookmark',
      child: IconButton(
        icon: const Icon(Icons.bookmark_add_outlined),
        color: AppColors.textPrimary,
        iconSize: 22,
        onPressed: itemId == null ? null : () => _addBookmark(context, ref),
      ),
    );
  }

  void _addBookmark(BuildContext context, WidgetRef ref) {
    final player = ref.read(playerProvider);
    final id = itemId;
    if (id == null) return;
    final bookSeconds =
        player.chapterStartInBook + player.position.inMilliseconds / 1000.0;

    final prefs = ref.read(sharedPrefsProvider);
    final raw = prefs.getString(_bookmarksPrefsKey);
    final Map<String, dynamic> all =
        raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
    final list = (all[id] as List<dynamic>? ?? []).cast<num>().toList();
    list.add(bookSeconds);
    all[id] = list;
    prefs.setString(_bookmarksPrefsKey, jsonEncode(all));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Bookmarked at ${player.position.mmss} into Chapter ${player.chapterIndex + 1}'),
        duration: const Duration(seconds: 2),
        backgroundColor: AppColors.surfaceElevated,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Bookmarked whole-book-timeline positions for [itemId], oldest first.
List<double> readBookmarks(WidgetRef ref, String itemId) {
  final prefs = ref.read(sharedPrefsProvider);
  final raw = prefs.getString(_bookmarksPrefsKey);
  if (raw == null) return const [];
  final all = jsonDecode(raw) as Map<String, dynamic>;
  return (all[itemId] as List<dynamic>? ?? [])
      .cast<num>()
      .map((n) => n.toDouble())
      .toList();
}
