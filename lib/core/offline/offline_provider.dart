import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/abs_item.dart';
import '../network/abs_client.dart';
import '../network/backend_client.dart';
import '../providers/config_provider.dart';
import '../providers/shared_prefs_provider.dart';
import 'offline_db.dart';

/// Live progress of an in-flight (or failed) book download.
class DownloadProgress {
  final int totalFiles;
  final int completedFiles;

  /// 0..1 progress of the file currently being downloaded.
  final double fileProgress;

  /// ino of the file currently in flight — lets the chapter list show a
  /// spinner on exactly the tile being fetched.
  final String? currentIno;

  /// Non-null when the download ended with an error or was cancelled.
  final String? error;

  const DownloadProgress({
    this.totalFiles = 1,
    this.completedFiles = 0,
    this.fileProgress = 0,
    this.currentIno,
    this.error,
  });

  double get fraction {
    if (totalFiles == 0) return 0;
    return ((completedFiles + fileProgress) / totalFiles).clamp(0.0, 1.0);
  }

  bool get isRunning => error == null;
}

class OfflineStoreState {
  /// itemId → downloaded book.
  final Map<String, OfflineBook> books;

  /// itemId → live download progress (only while downloading / on failure).
  final Map<String, DownloadProgress> downloads;

  /// itemId → set of audio-file inos actually stored on disk. A book is
  /// fully offline when this covers every file in its item JSON.
  final Map<String, Set<String>> chapters;

  const OfflineStoreState({
    this.books = const {},
    this.downloads = const {},
    this.chapters = const {},
  });

  OfflineBook? bookFor(String itemId) => books[itemId];

  DownloadProgress? progressFor(String itemId) => downloads[itemId];

  bool isDownloaded(String itemId) => books.containsKey(itemId);

  /// Number of audio files of [itemId] already stored on disk.
  int downloadedChapterCount(String itemId) => chapters[itemId]?.length ?? 0;

  /// True when the specific audio file [ino] of [itemId] is on disk.
  bool isChapterDownloaded(String itemId, String ino) =>
      ino.isNotEmpty && (chapters[itemId]?.contains(ino) ?? false);

  /// True when every audio file referenced by the book's item JSON exists on
  /// disk (i.e. the whole book plays offline). Single-file books count too.
  bool isFullyDownloaded(String itemId) {
    final book = books[itemId];
    if (book == null) return false;
    final inos = chapters[itemId];
    if (inos == null || inos.isEmpty) return false;
    try {
      final item = AbsItem.fromJson(
        jsonDecode(book.itemJson) as Map<String, dynamic>,
      );
      final all = item.audioFiles.map((f) => f.ino).where((i) => i.isNotEmpty);
      if (all.isEmpty) return false;
      return all.every(inos.contains);
    } catch (_) {
      return false;
    }
  }

  OfflineStoreState copyWith({
    Map<String, OfflineBook>? books,
    Map<String, DownloadProgress>? downloads,
    Map<String, Set<String>>? chapters,
  }) =>
      OfflineStoreState(
        books: books ?? this.books,
        downloads: downloads ?? this.downloads,
        chapters: chapters ?? this.chapters,
      );
}

/// Downloads audiobooks (audio files + cover + transcripts) to app storage
/// and tracks the set of books available offline.
class OfflineController extends Notifier<OfflineStoreState> {
  final Set<String> _active = {};
  final Map<String, CancelToken> _cancelTokens = {};

  @override
  OfflineStoreState build() {
    unawaited(_hydrate());
    return const OfflineStoreState();
  }

  Future<void> _hydrate() async {
    try {
      final books = await OfflineDatabase.all();
      final chapters = await OfflineDatabase.allChapters();
      // Merge instead of replace: a download that completed while the DB was
      // opening must not be wiped out by the hydration snapshot.
      state = OfflineStoreState(
        books: {
          ...state.books,
          for (final b in books) b.itemId: b,
        },
        chapters: {
          ...state.chapters,
          for (final e in chapters.entries) e.key: e.value,
        },
        downloads: state.downloads,
      );
    } catch (e) {
      debugPrint('offline: failed to load downloaded books: $e');
    }
  }

  /// Downloads audio files for [itemId].
  ///
  /// [inos] restricts the run to specific files (single-chapter download);
  /// null downloads the whole book. Either way the run is **resumable**:
  /// files that already exist on disk (tracked in `offline_chapters`) are
  /// skipped, so a failed/interrupted download continues where it stopped.
  Future<void> download(String itemId, {Set<String>? inos}) async {
    if (_active.contains(itemId)) return;

    final config = ref.read(configProvider);
    if (!config.isConfigured) {
      _setProgress(itemId, const DownloadProgress(error: 'Not configured'));
      return;
    }

    _active.add(itemId);
    final token = CancelToken();
    _cancelTokens[itemId] = token;

    try {
      final abs = ref.read(absClientProvider);
      final res = await abs.get('/api/items/$itemId');
      if (res.statusCode != 200) {
        throw Exception('Failed to load book (HTTP ${res.statusCode})');
      }
      final item = AbsItem.fromJson(res.data as Map<String, dynamic>);
      if (item.audioFiles.isEmpty) {
        throw Exception('Book has no audio files to download');
      }

      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${appDir.path}/offline/$itemId');
      await dir.create(recursive: true);

      // Which files are already on disk from a previous run?
      final have = {...(state.chapters[itemId] ?? const <String>{})};
      // Verify the marks against reality — a wiped folder would otherwise
      // leave phantom "downloaded" marks behind.
      final checked = <String>{};
      for (final ino in have) {
        final f = item.audioFiles.firstWhere(
          (f) => f.ino == ino,
          orElse: () => const AbsAudioFile(ino: '', duration: 0, filename: ''),
        );
        if (f.ino.isEmpty) continue;
        if (await File('${dir.path}/${f.offlineFilename}').exists()) {
          checked.add(ino);
        }
      }

      final wanted = inos == null
          ? item.audioFiles
          : item.audioFiles.where((f) => inos.contains(f.ino)).toList();
      final pending = wanted
          .where((f) => f.ino.isNotEmpty && !checked.contains(f.ino))
          .toList();

      final alreadyDone = wanted.length - pending.length;
      final totalFiles = wanted.length;
      var completed = alreadyDone;
      var totalBytes = 0;

      _setProgress(
        itemId,
        DownloadProgress(totalFiles: totalFiles, completedFiles: completed),
      );
      if (pending.isEmpty) {
        debugPrint('offline: $itemId already downloaded, nothing to do');
      }

      for (final f in pending) {
        if (!_active.contains(itemId)) return; // cancelled via remove()
        // ABS serves these files; only accept real 2xx responses so an error
        // page is never written to disk as a fake audio file.
        final savePath = '${dir.path}/${f.offlineFilename}';
        final url = '${config.absUrl}/api/items/$itemId/file/${f.ino}';

        Exception? lastError;
        // Two retries on transient connection errors — phone WiFi to a LAN
        // server occasionally drops mid-transfer on long downloads.
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            await abs.download(
              url,
              savePath,
              cancelToken: token,
              options: Options(
                receiveTimeout: const Duration(minutes: 10),
                validateStatus: (s) => s != null && s >= 200 && s < 300,
              ),
              onReceiveProgress: (received, total) {
                final fp = total <= 0 ? 0.0 : (received / total).clamp(0.0, 1.0);
                _setProgress(
                  itemId,
                  DownloadProgress(
                    totalFiles: totalFiles,
                    completedFiles: completed,
                    fileProgress: fp,
                    currentIno: f.ino,
                  ),
                );
              },
            );
            lastError = null;
            break;
          } on DioException catch (e) {
            if (CancelToken.isCancel(e)) rethrow;
            lastError = Exception(
                'Failed to download "${f.filename}" (file ${completed + 1} of $totalFiles): '
                '${e.type.name} ${e.response?.statusCode ?? ''}'.trim());
            // Give the server a beat before retrying.
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
        if (lastError != null) throw lastError;

        final saved = File(savePath);
        if (!await saved.exists() || await saved.length() == 0) {
          throw Exception('Downloaded file was empty: ${f.filename}');
        }
        final bytes = await saved.length();
        totalBytes += bytes;
        // Mark THIS chapter as downloaded (persisted) as soon as its file is
        // complete — a crash mid-run still leaves usable partial progress.
        await OfflineDatabase.markChapter(
          itemId,
          f.ino,
          fileName: f.offlineFilename,
          bytes: bytes,
        );
        state = state.copyWith(
          chapters: {
            ...state.chapters,
            itemId: {...(state.chapters[itemId] ?? const <String>{}), f.ino},
          },
        );
        completed++;
        _setProgress(
          itemId,
          DownloadProgress(
            totalFiles: totalFiles,
            completedFiles: completed,
          ),
        );
      }

      // Count bytes of files already present from a previous run so the size
      // shown in the UI stays correct after resuming.
      for (final ino in checked) {
        final f = item.audioFiles.firstWhere(
          (f) => f.ino == ino,
          orElse: () => const AbsAudioFile(ino: '', duration: 0, filename: ''),
        );
        if (f.ino.isEmpty) continue;
        try {
          totalBytes += await File('${dir.path}/${f.offlineFilename}').length();
        } catch (_) {}
      }

      if (completed == 0 && inos == null) {
        throw Exception('No audio files could be downloaded');
      }

      // Cover image (best effort — not fatal if it fails or is unavailable).
      // Kept from a previous run when resuming so it isn't re-downloaded.
      String? coverPath = state.books[itemId]?.coverPath;
      if (coverPath == null &&
          item.coverPath.isNotEmpty &&
          !item.coverPath.startsWith('http')) {
        try {
          coverPath = '${dir.path}/cover.jpg';
          await abs.download(
            '${config.absUrl}/api/items/$itemId/cover',
            coverPath,
            cancelToken: token,
            options: Options(
              validateStatus: (s) => s != null && s >= 200 && s < 300,
            ),
          );
          totalBytes += await File(coverPath).length();
        } catch (_) {
          coverPath = null;
        }
      }

      // Best-effort transcript cache: pull any already-transcribed VTTs so
      // the word-by-word reading view also works fully offline.
      await _cacheVttsFor(itemId, item.chapters.length);

      final existing = state.books[itemId];
      final book = OfflineBook(
        itemId: itemId,
        title: item.title,
        author: item.author,
        itemJson: jsonEncode(res.data),
        dirPath: dir.path,
        coverPath: coverPath ?? existing?.coverPath,
        sizeBytes: totalBytes,
        downloadedAt:
            existing?.downloadedAt ?? DateTime.now().millisecondsSinceEpoch,
      );
      await OfflineDatabase.upsert(book);

      state = state.copyWith(
        books: {...state.books, itemId: book},
        downloads: {...state.downloads}..remove(itemId),
      );
      debugPrint('offline: $itemId now has $completed/$totalFiles files '
          '(${state.isFullyDownloaded(itemId) ? 'complete' : 'partial'})');
    } catch (e) {
      if (!_active.contains(itemId)) return; // cancelled from remove()
      final cancelled = e is DioException && CancelToken.isCancel(e);
      final message = cancelled ? 'Download cancelled' : _friendlyError(e);
      debugPrint('offline: download of $itemId failed: $e');
      _setProgress(itemId, DownloadProgress(error: message));
      // Partial progress is intentionally KEPT — completed files stay marked
      // in offline_chapters, so the next "Download" / "Download remaining"
      // resumes instead of restarting from zero.
    } finally {
      _active.remove(itemId);
      _cancelTokens.remove(itemId);
    }
  }

  /// Convenience for the chapter list: download just one chapter's file.
  Future<void> downloadChapter(String itemId, String ino) =>
      download(itemId, inos: {ino});

  /// Cancels an in-flight download. The error handler in [download] surfaces
  /// the cancellation so the UI can offer retry / cleanup.
  void cancel(String itemId) {
    _cancelTokens[itemId]?.cancel();
  }

  /// Dismisses a failed/cancelled download entry from the UI.
  void dismissError(String itemId) {
    final downloads = {...state.downloads}..remove(itemId);
    state = state.copyWith(downloads: downloads);
  }

  /// Removes a downloaded book (folder + DB rows). If a download is in
  /// flight it is cancelled first.
  Future<void> remove(String itemId) async {
    _cancelTokens[itemId]?.cancel();
    _active.remove(itemId);
    _cancelTokens.remove(itemId);

    final book = state.books[itemId];
    if (book != null) {
      try {
        final dir = Directory(book.dirPath);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
      await OfflineDatabase.delete(itemId);
    }
    await OfflineDatabase.removeChaptersFor(itemId);

    state = state.copyWith(
      books: {...state.books}..remove(itemId),
      chapters: {...state.chapters}..remove(itemId),
      downloads: {...state.downloads}..remove(itemId),
    );
  }

  /// Deletes every downloaded book.
  Future<void> clearAll() async {
    for (final book in state.books.values.toList()) {
      await remove(book.itemId);
    }
  }

  Future<void> _cacheVttsFor(String itemId, int chapterCount) async {
    if (!ref.read(configProvider).backendConfigured) return;
    final backend = ref.read(backendClientProvider);
    try {
      final res = await backend.get('/api/jobs/book/$itemId');
      if (res.statusCode != 200) return;
      final data = res.data;
      if (data is! Map<String, dynamic>) return;
      Map<int, String> done = {};

      void add(Map<String, dynamic> m) {
        final idx = (m['chapter_index'] as num?)?.toInt();
        if (idx == null || idx < 0 || idx >= chapterCount) return;
        final status = m['status'] as String?;
        if (status == 'done') done[idx] = 'done';
      }

      final chapters = data['chapters'];
      if (chapters is List) {
        for (final e in chapters) {
          if (e is Map<String, dynamic>) add(e);
        }
      } else if (chapters is Map<String, dynamic>) {
        chapters.forEach((k, v) {
          final idx = int.tryParse(k);
          if (idx == null) return;
          if (v is Map<String, dynamic>) {
            v['chapter_index'] = idx;
            add(v);
          } else if (v == 'done') {
            done[idx] = 'done';
          }
        });
      }

      for (final ch in done.keys) {
        try {
          final vtt = await backend.get('/api/vtt/$itemId/$ch');
          if (vtt.statusCode == 200) {
            await ref
                .read(sharedPrefsProvider)
                .setString('vtt_${itemId}_$ch', vtt.data.toString());
          }
        } catch (_) {
          // keep going — transcript fetching is best effort
        }
      }
    } catch (_) {
      // backend unreachable — skip transcript caching
    }
  }

  void _setProgress(String itemId, DownloadProgress p) {
    state = state.copyWith(
      downloads: {...state.downloads, itemId: p},
    );
  }

  String _friendlyError(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return 'Connection to the server timed out. Check WiFi and try again.';
        case DioExceptionType.connectionError:
          return 'Could not reach the server. Check the address and WiFi.';
        case DioExceptionType.badResponse:
          return 'Server error (${e.response?.statusCode}) while downloading.';
        case DioExceptionType.cancel:
          return 'Download cancelled';
        default:
          return 'Download failed: ${e.message ?? e.type.name}';
      }
    }
    final text = e.toString();
    // Strip the generic "Exception: " wrapper for readability.
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}

final offlineStoreProvider =
    NotifierProvider<OfflineController, OfflineStoreState>(
        OfflineController.new);