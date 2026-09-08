import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'config_provider.dart';

/// Key prefix for the local per-book playback progress store.
///
/// Progress is also synced to the Audiobookshelf server while online (see
/// abs_sync.dart), but this local copy guarantees the user's place survives
/// app kills, backgrounding, and offline sessions where server sync gets
/// disabled after repeated failures. Every record is keyed by the stable
/// ABS item id — never the title — so a title/author rename can't orphan a
/// saved position.
const playbackProgressPrefsKey = 'playback_progress';

/// A single saved reading/listening position for one book.
class BookPlaybackProgress {
  const BookPlaybackProgress({
    required this.itemId,
    required this.chapterIndex,
    required this.positionSeconds,
    this.updatedAtEpochMs,
  });

  final String itemId;
  final int chapterIndex;

  /// Seconds since the start of [chapterIndex].
  final double positionSeconds;

  /// Epoch milliseconds of the last write — kept for debuggability and so a
  /// "Resume from X?" prompt can be added later without a migration.
  final int? updatedAtEpochMs;

  Map<String, dynamic> toJson() => {
    'chapterIndex': chapterIndex,
    'positionSeconds': positionSeconds,
    'updatedAt': updatedAtEpochMs ?? DateTime.now().millisecondsSinceEpoch,
  };

  static String keyFor(String itemId) => '${playbackProgressPrefsKey}_$itemId';

  /// Reads the saved progress for [itemId], or null when nothing (or
  /// corrupt data) is stored.
  static BookPlaybackProgress? fromPrefs(
    SharedPreferences prefs,
    String itemId,
  ) {
    final raw = prefs.getString(keyFor(itemId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final chapterIndex = (json['chapterIndex'] as num?)?.toInt();
      final positionSeconds = (json['positionSeconds'] as num?)?.toDouble();
      if (chapterIndex == null || positionSeconds == null) return null;
      return BookPlaybackProgress(
        itemId: itemId,
        chapterIndex: chapterIndex,
        positionSeconds: positionSeconds,
        updatedAtEpochMs: (json['updatedAt'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Persists the current position for [itemId] and keeps the legacy
  /// `last_played_chapter_*` key in sync so the book-detail "READ ALONG"
  /// continue button and the transcribe sheet keep targeting the right
  /// chapter.
  static Future<void> save(
    SharedPreferences prefs,
    String itemId,
    int chapterIndex,
    double positionSeconds,
  ) async {
    await prefs.setString(
      keyFor(itemId),
      jsonEncode(
        BookPlaybackProgress(
          itemId: itemId,
          chapterIndex: chapterIndex,
          positionSeconds: positionSeconds,
          updatedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
        ).toJson(),
      ),
    );
    await saveLastPlayedChapter(prefs, itemId, chapterIndex);
  }
}
