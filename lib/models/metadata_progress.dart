import 'abs_item.dart';

/// One book's progress row, as returned by the metadata server's
/// `GET /api/progress` (`books.<abs_item_id>`), the per-book GET, and the
/// POST/PUT book endpoints.
class MetadataBookProgress {
  final String absItemId;
  final bool isFinished;

  /// Last-played bookmark (drives "continue reading").
  final int? lastChapterIndex;
  final double? lastPositionSeconds;

  /// Whole-book 0..1 fraction rolled by the player. 1.0 when finished.
  final double progress;
  final String? updatedAt;

  const MetadataBookProgress({
    required this.absItemId,
    this.isFinished = false,
    this.lastChapterIndex,
    this.lastPositionSeconds,
    this.progress = 0,
    this.updatedAt,
  });

  factory MetadataBookProgress.fromJson(Map<String, dynamic> json) {
    final idx = json['last_chapter_index'];
    final pos = json['last_position_seconds'];
    final frac = json['progress'];
    return MetadataBookProgress(
      absItemId: (json['abs_item_id'] as String?) ?? '',
      isFinished: json['is_finished'] == true,
      lastChapterIndex: _parseInt(idx),
      lastPositionSeconds: _parseDouble(pos),
      progress: _parseDouble(frac) ?? 0,
      updatedAt: json['updated_at'] as String?,
    );
  }

  double get progressFraction => isFinished ? 1.0 : progress.clamp(0.0, 1.0);

  /// Whole-book timeline position in seconds — used for the library list
  /// progress strip and the "resume" computation. Requires chapter starts
  /// to place the bookmark on the book timeline; minified library items
  /// have no chapter data, so this degrades to the raw within-chapter
  /// offset (callers must not treat it as a book-timeline second there).
  double wholeBookSeconds(List<AbsChapter> chapters) {
    final idx = lastChapterIndex;
    final pos = lastPositionSeconds;
    if (idx == null || pos == null) return 0;
    if (idx < 0 || idx >= chapters.length) return pos;
    return chapters[idx].start + pos;
  }
}

int? _parseInt(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _parseDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// The response shape of `GET /api/progress` — the one call the client
/// makes right after login to populate its three local stores (listened
/// marks, per-chapter positions, continue-reading bookmarks) in a single
/// round trip.
class MetadataBulkProgress {
  final Map<String, MetadataBookProgress> bookProgress;
  final Map<String, List<int>> chaptersDone;
  final Map<String, Map<int, double>> chapterPositions;

  const MetadataBulkProgress({
    required this.bookProgress,
    required this.chaptersDone,
    required this.chapterPositions,
  });

  static MetadataBulkProgress? fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    final data = json;

    Map<String, MetadataBookProgress> books = <String, MetadataBookProgress>{};
    final rawBooks = data['books'];
    if (rawBooks is Map) {
      for (final mapEntry in rawBooks.entries) {
        final key = '${mapEntry.key}';
        final value = mapEntry.value;
        if (value is! Map) continue;
        books[key] = MetadataBookProgress.fromJson(
          Map<String, dynamic>.from(value),
        );
      }
    }

    final done = <String, List<int>>{};
    final rawDone = data['chapters_done'];
    if (rawDone is Map) {
      for (final mapEntry in rawDone.entries) {
        final key = '${mapEntry.key}';
        final value = mapEntry.value;
        if (value is! List) continue;
        final list = <int>[];
        for (final e in value) {
          final i = e is num ? e.toInt() : int.tryParse('$e');
          if (i != null && i >= 0) list.add(i);
        }
        done[key] = list;
      }
    }

    final positions = <String, Map<int, double>>{};
    final rawPos = data['chapter_positions'];
    if (rawPos is Map) {
      for (final mapEntry in rawPos.entries) {
        final key = '${mapEntry.key}';
        final value = mapEntry.value;
        if (value is! Map) continue;
        final inner = <int, double>{};
        for (final innerEntry in value.entries) {
          final idx = int.tryParse('${innerEntry.key}');
          final pos = _parseDouble(innerEntry.value);
          if (idx != null && idx >= 0 && pos != null && pos >= 0) {
            inner[idx] = pos;
          }
        }
        positions[key] = inner;
      }
    }

    return MetadataBulkProgress(
      bookProgress: books,
      chaptersDone: done,
      chapterPositions: positions,
    );
  }
}