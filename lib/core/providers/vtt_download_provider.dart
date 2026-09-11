import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/backend_client.dart';
import '../providers/config_provider.dart';
import '../providers/shared_prefs_provider.dart';

/// Manual "Download transcripts" bulk-fetch: pulls every `done` chapter's
/// VTT from the unified backend and persists it to the SharedPreferences
/// cache (`vtt_{itemId}_{ch}` — the exact keys the player's `_loadVtt`
/// reads when the backend is unreachable). After this runs, playback can
/// continue through ABS with a working read-along even when the backend
/// server is down.
///
/// Lives in core/ (not features/player) because it is triggered from two
/// places: the book detail screen and the player's overflow menu.
enum VttDownloadStatus { idle, running, success, error }

class VttDownloadState {
  final VttDownloadStatus status;

  /// Chapters found on the backend with a finished transcription.
  final int totalCount;

  /// Chapters fetched + persisted this run (0 while idle).
  final int doneCount;

  /// Chapters that were already in the local cache and got skipped.
  final int alreadyCached;

  final String? error;

  const VttDownloadState({
    this.status = VttDownloadStatus.idle,
    this.totalCount = 0,
    this.doneCount = 0,
    this.alreadyCached = 0,
    this.error,
  });

  bool get isRunning => status == VttDownloadStatus.running;
}

class VttDownloadController
    extends FamilyNotifier<VttDownloadState, String> {
  @override
  VttDownloadState build(String arg) => const VttDownloadState();

  /// Prefers a human-readable message for [e], matching the tone of
  /// offline_provider's `_friendlyError`.
  String _friendlyError(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return 'Connection to the server timed out.';
        case DioExceptionType.connectionError:
          return 'Could not reach the server. Check the address and WiFi.';
        case DioExceptionType.badResponse:
          return 'Server error (${e.response?.statusCode}).';
        case DioExceptionType.cancel:
          return 'Cancelled';
        default:
          return 'Download failed: ${e.message ?? e.type.name}';
      }
    }
    return e.toString();
  }

  /// Fetches + caches every `done` chapter's VTT for [itemId]. Skips
  /// chapters already cached unless [force] is set. Returns true on
  /// success (including "nothing to fetch").
  Future<bool> start(String itemId, {bool force = false}) async {
    if (!ref.read(configProvider).serverConfigured) {
      state = const VttDownloadState(
        status: VttDownloadStatus.error,
        error: 'No transcription server configured',
      );
      return false;
    }

    state = const VttDownloadState(status: VttDownloadStatus.running);
    final backend = ref.read(backendClientProvider);
    final prefs = ref.read(sharedPrefsProvider);

    try {
      final jobsRes = await backend.get('/api/jobs/book/$itemId');
      if (jobsRes.statusCode != 200) {
        state = VttDownloadState(
          status: VttDownloadStatus.error,
          error: 'Server error (${jobsRes.statusCode}) listing jobs.',
        );
        return false;
      }
      final data = jobsRes.data;
      if (data is! Map<String, dynamic>) {
        state = const VttDownloadState(
          status: VttDownloadStatus.error,
          error: 'Unexpected server response.',
        );
        return false;
      }

      // Collect `done` chapter indices. The endpoint returns either
      // {"chapters": [ {..., chapter_index, status} ]} (list or map keyed
      // by index — see book_detail_provider's matching parser) or a flat
      // map of index → status.
      final doneIdx = <int>{};
      void addJob(Map<String, dynamic> m) {
        final idx = (m['chapter_index'] as num?)?.toInt();
        if (idx != null && idx >= 0 && m['status'] == 'done') doneIdx.add(idx);
      }

      final chapters = data['chapters'];
      if (chapters is List) {
        for (final e in chapters) {
          if (e is Map<String, dynamic>) addJob(e);
        }
      } else if (chapters is Map<String, dynamic>) {
        chapters.forEach((k, v) {
          final idx = int.tryParse(k);
          if (idx == null) return;
          if (v is Map<String, dynamic>) {
            v['chapter_index'] = idx;
            addJob(v);
          } else if (v == 'done') {
            doneIdx.add(idx);
          }
        });
      }

      if (doneIdx.isEmpty) {
        state = const VttDownloadState(
          status: VttDownloadStatus.error,
          error: 'No transcribed chapters on the server yet.',
        );
        return false;
      }

      var fetched = 0;
      var skipped = 0;
      for (final ch in doneIdx.toList()..sort()) {
        final key = 'vtt_${itemId}_$ch';
        if (!force && prefs.getString(key) != null) {
          skipped++;
          state = VttDownloadState(
            status: VttDownloadStatus.running,
            totalCount: doneIdx.length,
            doneCount: fetched,
            alreadyCached: skipped,
          );
          continue;
        }
        try {
          final vttRes = await backend.get('/api/vtt/$itemId/$ch');
          if (vttRes.statusCode == 200) {
            await prefs.setString(key, vttRes.data.toString());
            fetched++;
          }
        } catch (_) {
          // One chapter failing shouldn't abort the rest.
        }
        state = VttDownloadState(
          status: VttDownloadStatus.running,
          totalCount: doneIdx.length,
          doneCount: fetched,
          alreadyCached: skipped,
        );
      }

      state = VttDownloadState(
        status: VttDownloadStatus.success,
        totalCount: doneIdx.length,
        doneCount: fetched,
        alreadyCached: skipped,
      );
      return true;
    } catch (e) {
      state = VttDownloadState(
        status: VttDownloadStatus.error,
        error: _friendlyError(e),
      );
      return false;
    }
  }

  void reset() => state = const VttDownloadState();
}

/// itemId-scoped download state so the book detail screen and the player
/// can watch different books without clobbering each other.
final vttDownloadProvider = NotifierProvider.family<VttDownloadController,
    VttDownloadState, String>(VttDownloadController.new);
