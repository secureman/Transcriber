import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/abs_client.dart';
import '../../core/network/backend_client.dart';
import '../../core/providers/config_provider.dart';
import '../../models/abs_item.dart';

/// Status of a chapter's transcription job.
class ChapterJobStatus {
  static const done = 'done';
  static const processing = 'processing';
  static const pending = 'pending';
  static const error = 'error';

  final int chapterIndex;
  final String status;
  final double progress; // 0..100 (0 when unknown/not started)
  final String? errorMessage;

  const ChapterJobStatus({
    required this.chapterIndex,
    required this.status,
    this.progress = 0,
    this.errorMessage,
  });

  bool get isDone => status == done;
  bool get isProcessing => status == processing || status == pending;
  bool get isError => status == error;

  double get progressFraction => progress.clamp(0.0, 100.0) / 100.0;
}

/// Fetches book metadata from the transcription backend, falling back to the
/// ABS server directly if the backend proxy fails.
final bookDetailProvider =
    FutureProvider.family<AbsItem, String>((ref, itemId) async {
  final backend = ref.read(backendClientProvider);
  final abs = ref.read(absClientProvider);

  try {
    final res = await backend.get('/api/metadata/$itemId');
    if (res.statusCode == 200) {
      final data = res.data;
      if (data is Map<String, dynamic>) {
        if (data['media'] != null) return AbsItem.fromJson(data);
        if (data['item'] is Map<String, dynamic>) {
          return AbsItem.fromJson(data['item'] as Map<String, dynamic>);
        }
        // Backend BookMeta shape: {item_id, title, author, cover_url, duration, chapters}
        if (data['item_id'] is String && data['chapters'] is List) {
          return AbsItem.fromBackendMeta(data);
        }
      }
      throw const FormatException('Unrecognized metadata shape');
    }
  } on DioException {
    // fall through to direct ABS fetch
  }

  final absRes = await abs.get('/api/items/$itemId');
  if (absRes.statusCode != 200) {
    throw Exception('Failed to load book (HTTP ${absRes.statusCode})');
  }
  return AbsItem.fromJson(absRes.data as Map<String, dynamic>);
});

/// Polls transcription job statuses for a book every 4 seconds.
/// Stops polling once no chapter is pending/processing.
final chapterStatusProvider =
    StreamProvider.family<Map<int, ChapterJobStatus>, String>(
  (ref, itemId) async* {
    // watch() so a config change (added/removed backend URL) re-evaluates
    // this stream — otherwise the user could edit the URL in settings
    // and the polling would still see the old "no backend" branch.
    if (!ref.watch(configProvider).backendConfigured) {
      yield const {};
      return;
    }
    final backend = ref.read(backendClientProvider);

    while (true) {
      Map<int, ChapterJobStatus> statuses = {};
      try {
        final res = await backend.get('/api/jobs/book/$itemId');
        statuses = _parseJobs(res.data);
      } on DioException {
        statuses = {};
      }

      yield statuses;

      final active =
          statuses.values.any((s) => s.isProcessing);
      if (!active) break;
      await Future<void>.delayed(const Duration(seconds: 4));
    }
  },
);

/// One currently-transcribing job, as returned by /api/jobs/active.
class ActiveJob {
  final String jobId;
  final String bookId;
  final String bookTitle;
  final int chapterIndex;
  final String chapterTitle;
  final double progress;
  final int durationSeconds;

  const ActiveJob({
    required this.jobId,
    required this.bookId,
    required this.bookTitle,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.progress,
    required this.durationSeconds,
  });

  factory ActiveJob.fromJson(Map<String, dynamic> json) => ActiveJob(
        jobId: (json['job_id'] as String?) ?? '',
        bookId: (json['book_id'] as String?) ?? '',
        bookTitle: (json['book_title'] as String?) ?? 'Unknown',
        chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
        chapterTitle: (json['chapter_title'] as String?) ?? 'Chapter',
        progress: ((json['progress'] as num?)?.toDouble() ?? 0).clamp(0, 100),
        durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
      );
}

/// Polls /api/jobs/active every 5s and yields the list of jobs currently
/// being transcribed across ALL books. Stops when the list is empty and
/// the user navigates away (auto-dispose).
final activeJobsProvider =
    StreamProvider.autoDispose<List<ActiveJob>>((ref) async* {
  if (!ref.read(configProvider).backendConfigured) {
    yield const [];
    return;
  }
  final backend = ref.read(backendClientProvider);
  // Emit the first snapshot immediately, then on the 5s tick.
  while (true) {
    try {
      final res = await backend.get('/api/jobs/active');
      if (res.statusCode == 200 && res.data is Map) {
        final list = (res.data['active'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ActiveJob.fromJson)
            .toList();
        yield list;
        if (list.isEmpty) {
          // Nothing in flight — wait longer so we don't hammer the server.
          await Future<void>.delayed(const Duration(seconds: 10));
          continue;
        }
      } else {
        yield const [];
      }
    } on DioException {
      // Transient network blip → keep the last snapshot, just wait.
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});



/// Accepts:
///   [ {"chapter_index": 0, "status": "done"}, ... ]
///   {"jobs": [...]}
///   {"0": "done", "1": "processing"}
///   {"chapters": {"0": {"status": "done"}, ...}}
///   Backend spec: {"book_id": ..., "chapters": [ {chapter_index, status, progress, error_message} ]}
Map<int, ChapterJobStatus> _parseJobs(dynamic data) {
  final out = <int, ChapterJobStatus>{};
  List<dynamic>? list;
  if (data is List) {
    list = data;
  } else if (data is Map<String, dynamic>) {
    if (data['jobs'] is List) list = data['jobs'] as List<dynamic>;
  }

  int? readIndex(Map<String, dynamic> j) {
    for (final k in ['chapter_index', 'chapterIndex', 'chapter', 'index']) {
      final v = j[k];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
    }
    return null;
  }

  String? readStatus(Map<String, dynamic> j) {
    for (final k in ['status', 'state']) {
      final v = j[k];
      if (v is String) return v;
    }
    return null;
  }

  double readProgress(Map<String, dynamic> j) =>
      (j['progress'] as num?)?.toDouble() ?? 0;

  String? readError(Map<String, dynamic> j) =>
      (j['error_message'] as String?) ?? (j['error'] as String?);

  void add(Map<String, dynamic> j) {
    final idx = readIndex(j);
    final st = readStatus(j);
    if (idx != null && st != null) {
      out[idx] = ChapterJobStatus(
        chapterIndex: idx,
        status: st,
        progress: readProgress(j),
        errorMessage: readError(j),
      );
    }
  }

  if (list != null) {
    for (final e in list) {
      if (e is Map<String, dynamic>) add(e);
    }
    return out;
  }

  if (data is Map<String, dynamic>) {
    // Backend spec shape: {"book_id": "...", "chapters": [ {chapter_index, status}, ... ]}
    if (data['chapters'] is List) {
      for (final e in data['chapters'] as List<dynamic>) {
        if (e is Map<String, dynamic>) add(e);
      }
      return out;
    }
    final chapters = data['chapters'];
    if (chapters is Map<String, dynamic>) {
      chapters.forEach((key, value) {
        final idx = int.tryParse(key);
        if (idx == null) return;
        if (value is Map<String, dynamic>) {
          value['chapter_index'] = idx;
          add(value);
        } else if (value is String) {
          out[idx] =
              ChapterJobStatus(chapterIndex: idx, status: value);
        }
      });
      return out;
    }
    // Flat map of chapter index → status.
    data.forEach((key, value) {
      final idx = int.tryParse(key);
      if (idx == null) return;
      if (value is Map<String, dynamic>) {
        value['chapter_index'] = idx;
        add(value);
      } else if (value is String) {
        out[idx] =
            ChapterJobStatus(chapterIndex: idx, status: value);
      }
    });
  }
  return out;
}

class TranscribeMode {
  static const chapter = 'chapter';
  static const next5 = 'next5';
  static const book = 'book';
}

class TranscribeState {
  final bool submitting;
  final String? error;

  const TranscribeState({this.submitting = false, this.error});
}

class TranscribeController extends Notifier<TranscribeState> {
  @override
  TranscribeState build() => const TranscribeState();

  /// POSTs a transcription request to the backend.
  Future<bool> start({
    required String itemId,
    required String mode,
    required int chapterIndex,
    required int totalChapters,
  }) async {
    if (!ref.read(configProvider).backendConfigured) {
      state = const TranscribeState(
          error: 'No transcription server configured');
      return false;
    }
    state = const TranscribeState(submitting: true);
    try {
      final backend = ref.read(backendClientProvider);
      // Backend contract: mode ∈ {full, chapter, range}.
      final Map<String, dynamic> body;
      switch (mode) {
        case TranscribeMode.chapter:
          body = {
            'abs_item_id': itemId,
            'mode': 'chapter',
            'chapter_index': chapterIndex,
          };
        case TranscribeMode.next5:
          body = {
            'abs_item_id': itemId,
            'mode': 'range',
            'from_chapter': chapterIndex,
            'count': 5,
          };
        default: // book
          body = {
            'abs_item_id': itemId,
            'mode': 'full',
          };
      }
      final res = await backend.post('/api/transcribe', data: body);
      final ok = res.statusCode != null && res.statusCode! < 300 ||
          res.statusCode == 202;
      state = const TranscribeState();
      if (ok) ref.invalidate(chapterStatusProvider(itemId));
      return ok;
    } on DioException catch (e) {
      state = TranscribeState(
          error: 'Transcription request failed: '
              '${e.response?.statusCode ?? e.message}');
      return false;
    } catch (e) {
      state = TranscribeState(error: e.toString());
      return false;
    }
  }
}

final transcribeProvider =
    NotifierProvider<TranscribeController, TranscribeState>(
        TranscribeController.new);

