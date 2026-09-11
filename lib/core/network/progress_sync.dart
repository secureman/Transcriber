import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/config_provider.dart';
import 'metadata_client.dart';

/// Writes reading progress to the metadata server. Every method is a
/// fire-and-forget background push: local state always wins and failures
/// are swallowed (the next sync tick or the next app start's bulk restore
/// reconciles the server).
class ProgressSyncer {
  ProgressSyncer(this.ref);

  final Ref ref;

  bool get _enabled {
    final config = ref.read(configProvider);
    return config.serverConfigured && config.absToken.isNotEmpty;
  }

  /// Marks a chapter as listened (idempotent on the server).
  Future<bool> chapterDone(String itemId, int chapterIndex) => _send(
        (dio) => dio.post(
          '/api/progress/chapter/$itemId/$chapterIndex/done',
        ),
      );

  /// Clears a chapter's listened mark (idempotent on the server).
  Future<bool> chapterNotDone(String itemId, int chapterIndex) => _send(
        (dio) => dio.delete(
          '/api/progress/chapter/$itemId/$chapterIndex/done',
        ),
      );

  /// Stores a chapter's playback position in seconds (also refreshes the
  /// book-level "continue reading" bookmark on the server).
  Future<bool> chapterPosition(
    String itemId,
    int chapterIndex,
    double positionSec,
  ) =>
      _send(
        (dio) => dio.put(
          '/api/progress/chapter/$itemId/$chapterIndex/position',
          data: {'position_seconds': positionSec},
        ),
      );

  /// Replaces the book's whole chapter-done set (whole-book listened
  /// toggle). Empty set ⇒ all cleared.
  Future<bool> replaceBookChapters(String itemId, Set<int> chapters) =>
      _send(
        (dio) => dio.put(
          '/api/progress/book/$itemId/chapters',
          data: {'chapters': chapters.toList()},
        ),
      );

  /// Whole-book rolling sync from the player — refreshes the bookmark and
  /// the whole-book fraction in one call (mirrors the old ABS
  /// `/api/me/progress` PATCH).
  Future<bool> bookProgress({
    required String itemId,
    required int chapterIndex,
    required double positionSec,
    required double progressFraction,
  }) =>
      _send(
        (dio) => dio.put(
          '/api/progress/book/$itemId',
          data: {
            'last_chapter_index': chapterIndex,
            'last_position_seconds': positionSec,
            'progress': progressFraction.clamp(0.0, 1.0),
          },
        ),
      );

  /// Sets / clears the whole-book finished flag.
  Future<bool> bookFinished(String itemId, bool isFinished) => _send(
        (dio) => dio.post(
          '/api/progress/book/$itemId/finished',
          data: {'is_finished': isFinished},
        ),
      );

  Future<bool> _send(Future<Response<dynamic>> Function(Dio) run) async {
    if (!_enabled) return false;
    try {
      final res = await run(ref.read(metadataClientProvider));
      final code = res.statusCode;
      return code != null && code < 300;
    } catch (_) {
      return false;
    }
  }
}

final progressSyncProvider = Provider<ProgressSyncer>(
  (ref) => ProgressSyncer(ref),
);