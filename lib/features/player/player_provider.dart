import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import '../../core/network/abs_client.dart';
import '../../core/network/backend_client.dart';
import '../../core/network/progress_sync.dart';
import '../../core/offline/offline_provider.dart';
import '../../core/providers/config_provider.dart';
import '../../core/providers/playback_progress_provider.dart';
import '../../core/providers/read_chapters_provider.dart';
import '../../core/providers/shared_prefs_provider.dart';
import '../../core/utils/duration_ext.dart';
import '../../core/utils/vtt_parser.dart';
import '../../models/abs_item.dart';
import 'audio_handler.dart';
import 'player_state.dart';

class PlayerController extends Notifier<PlayerState> {
  Timer? _vttPollTimer;
  Timer? _sleepTimer;
  // One-shot 45s VTT retry: armed when a chapter has no transcript AND no
  // cached copy because the backend was unreachable (transcription jobs
  // keep running server-side, so the VTT can simply appear later). Canceled
  // by any successful VTT apply, chapter switch, or dispose.
  Timer? _vttRetryTimer;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<ProcessingState>? _processingSub;
  // BUG FIX v1: track playing state so play/pause button reflects reality.
  StreamSubscription<bool>? _playingSub;
  // Auto-advance detection: just_audio 0.10's setAudioSources playlist
  // emits 1 when the current source ends and the queue advances to the
  // prefetched next. Listening for that lets us replace the old
  // processingState.completed chapter-end hook (which the playlist no
  // longer fires mid-playlist).
  StreamSubscription<int?>? _currentIndexSub;
  int _lastEmitMs = 0;
  int _loadedChapterIndex = -1;

  // Full item kept around so the auto-advance path can rebuild the
  // queue (compute next-chapter sources) without re-fetching the item
  // from ABS on every chapter boundary.
  AbsItem? _loadedItem;

  // ── ABS progress sync ─────────────────────────────────────────────
  String? _syncItemId;
  double _syncBookDuration = 0;
  double _syncChapterStart = 0;
  // How far into the current chapter the loaded ClippingAudioSource's clip
  // actually starts, in seconds — 0 for a normal chapter load, non-zero
  // when _loadAudio resumed mid-chapter (see the resumeTarget logic there).
  // Needed because ClippingAudioSource reports position relative to its own
  // `start` boundary, not the chapter's true start, so every raw position
  // tick and every seek target must be corrected by this amount to stay in
  // "seconds since chapter start" terms — which is what VTT cue timestamps,
  // the chapter scrubber, and the whole-book ABS progress math all assume.
  double _chapterOffsetSeconds = 0;
  int _syncStartedAt = 0;
  Duration _lastPosition = Duration.zero;
  // Backoff for transient sync failures (offline, server briefly down).
  // Unlike the old all-or-nothing disable, this retries with increasing
  // delay so sync self-recovers when the server comes back.
  int _syncFailures = 0;
  int _lastSyncMs = 0;

  // ── Local progress persistence ─────────────────────────────────────
  // Independent of the ABS sync throttle so the user's exact place
  // survives hard kills and offline sessions (server sync disables itself
  // after repeated failures). Saved every 5s while playing, on pause, on
  // chapter change, on dispose/backgrounding, and in _cleanup.
  Timer? _progressTimer;

  // ── VTT cache helpers ──────────────────────────────────────────────
  // Keyed by "vtt_$itemId_$chapterIndex". VTTs are typically 100–400 KB;
  // SharedPreferences can handle this fine on Android/iOS.

  static String _cacheKey(String itemId, int ch) => 'vtt_${itemId}_$ch';

  String? _readCache(String itemId, int ch) =>
      ref.read(sharedPrefsProvider).getString(_cacheKey(itemId, ch));

  Future<void> _writeCache(String itemId, int ch, String vtt) =>
      ref.read(sharedPrefsProvider).setString(_cacheKey(itemId, ch), vtt);

  @override
  PlayerState build() {
    ref.onDispose(_cleanup);
    return const PlayerState();
  }

  void _cleanup() {
    _vttPollTimer?.cancel();
    _vttRetryTimer?.cancel();
    _sleepTimer?.cancel();
    _positionSub?.cancel();
    _processingSub?.cancel();
    _playingSub?.cancel();
    _progressTimer?.cancel();
    // Best-effort final progress flush when leaving the player / app.
    _saveLocalProgress();
    _syncProgress();
  }

  Future<void> init(String itemId, int chapterIndex) async {
    // BUG FIX v1: also require audioReady so a failed load doesn't
    // permanently block retries via this early-return guard.
    if (state.itemId == itemId &&
        _loadedChapterIndex == chapterIndex &&
        state.audioReady) {
      return;
    }

    _vttPollTimer?.cancel();
    _positionSub?.cancel();
    _processingSub?.cancel();
    _playingSub?.cancel();
    _currentIndexSub?.cancel();
    _loadedChapterIndex = chapterIndex;

    // Fresh progress-sync context for this book.
    _syncItemId = itemId;
    _syncBookDuration = 0;
    _syncChapterStart = 0;
    _chapterOffsetSeconds = 0;
    _syncFailures = 0;
    _lastSyncMs = 0;

    final prefs = ref.read(sharedPrefsProvider);
    final lastSize = prefs.getDouble('reading_font_size') ?? 22;
    // Carry over the last-used speed both for this session's scrubber math
    // and so setSpeed() doesn't blast 1.0 over the persisted value when the
    // user never touches the control.
    final lastSpeed = prefs.getDouble(kPlaybackSpeedKey) ?? 1.0;
    // The audio handler is freshly constructed at 1.0 — apply the persisted
    // speed straight to the underlying player without re-writing the same
    // value to prefs.
    unawaited(ref.read(audioHandlerProvider).player.setSpeed(lastSpeed));

    state = PlayerState(
      itemId: itemId,
      chapterIndex: chapterIndex,
      vttStatus: VttStatus.loading,
      readingFontSize: lastSize,
      speed: lastSpeed,
    );

    // BUG FIX v1: catch audio errors so VTT still loads.
    await Future.wait([
      _loadAudio(itemId, chapterIndex).catchError((Object e) {}),
      _loadVtt(itemId, chapterIndex),
    ]);

    _startSyncListener();
    // Periodically persist position locally (independent of the 10s ABS sync
    // throttle) so a hard kill never loses more than ~5s of progress.
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveLocalProgress(),
    );
    await saveLastPlayedChapter(prefs, itemId, chapterIndex);
  }

  Future<void> _loadAudio(String itemId, int chapterIndex) async {
    final config = ref.read(configProvider);
    final handler = ref.read(audioHandlerProvider);
    final abs = ref.read(absClientProvider);

    // Offline first: if this book was downloaded for offline use, play the
    // local files — no network required at all.
    final offlineBook = ref.read(offlineStoreProvider).books[itemId];

    final AbsItem item;
    if (offlineBook != null) {
      item = AbsItem.fromJson(
        jsonDecode(offlineBook.itemJson) as Map<String, dynamic>,
      );
    } else {
      final res = await abs.get('/api/items/$itemId?expanded=1');
      if (res.statusCode != 200) {
        throw Exception('Failed to load item (HTTP ${res.statusCode})');
      }
      item = AbsItem.fromJson(res.data as Map<String, dynamic>);
    }
    // Keep the full item so the auto-advance path can rebuild the
    // queue (compute next-chapter sources) without an extra ABS fetch.
    _loadedItem = item;

    final isArabic =
        item.isArabic ||
        (item.language?.toLowerCase().startsWith('ar') ?? false);

    if (item.chapters.isEmpty || item.audioFiles.isEmpty) {
      throw Exception('Book has no chapters or audio files');
    }

    final chIndex = chapterIndex.clamp(0, item.chapters.length - 1);
    final chapter = item.chapters[chIndex];
    final totalChapters = item.chapters.length;

    // Resume to the exact second, not just the top of the chapter.
    //
    // The metadata server owns the resumption position: after login its bulk
    // fetch populates the local playback-progress store, and the player
    // keeps that store fresh continuously. So prefer the local bookmark —
    // it's per-chapter exact. Fall back to the ABS `userMediaProgress`
    // position the item fetch happens to carry (legacy data ABS may still
    // hold from before the app moved progress to its own server), and
    // finally start at the chapter top for ordinary chapter navigation.
    final resumeTarget = item.resumeSeconds;
    final localProgress = BookPlaybackProgress.fromPrefs(
      ref.read(sharedPrefsProvider),
      itemId,
    );
    double seekSeconds;
    if (localProgress != null &&
        localProgress.chapterIndex == chIndex &&
        localProgress.positionSeconds > 0 &&
        localProgress.positionSeconds < chapter.duration) {
      // Metadata-server-derived bookmark — the source of truth.
      seekSeconds = chapter.start + localProgress.positionSeconds;
    } else if (resumeTarget != null &&
        resumeTarget >= chapter.start &&
        resumeTarget < chapter.end) {
      // Legacy ABS resume point — only when there is no local bookmark.
      seekSeconds = resumeTarget;
    } else {
      // No usable resume point (fresh book, ordinary navigation —
      // next/prev/tapped a different chapter), start at the chapter top.
      seekSeconds = chapter.start;
    }
    // How far into the chapter we're resuming — 0 for an ordinary (non-resume)
    // chapter load. Needed below to keep the file's end-boundary anchored to
    // the chapter's real end (not shifted forward by however far we skipped
    // ahead) and to show the correct position immediately instead of a
    // misleading "0:00" until the first position tick arrives.
    final chapterOffsetSeconds = seekSeconds - chapter.start;

    final files = item.audioFiles
        .map((f) => (ino: f.ino, duration: f.duration))
        .toList();
    final (ino, offsetInFile) = AudiobookAudioHandler.resolveFilePosition(
      files: files,
      seconds: seekSeconds,
    );
    // The file-position that corresponds to the chapter's true start (i.e.
    // undoing the resume skip-ahead), so the file's end boundary below is
    // computed the same way whether or not we're resuming mid-chapter.
    final chapterStartOffsetInFile = offsetInFile - chapterOffsetSeconds;

    final title = item.title;
    final artist = item.author.isEmpty ? null : item.author;
    final chapterNumber = chIndex + 1;

    // ── Next-chapter prefetch ────────────────────────────────────────
    // Compute the next chapter's clip bounds so the player can queue it
    // alongside the current one. just_audio 0.10's setAudioSources (with
    // useLazyPreparation, the default) fetches and buffers source[1] in
    // the background while source[0] plays — so the inter-chapter
    // transition is gapless. We skip the prefetch when the next chapter
    // spans multiple audio files (it can't be expressed as a single
    // ClippingAudioSource).
    String? nextFileIno;
    double? nextStartSec;
    double? nextEndSec;
    String? nextFilePath;
    if (chIndex + 1 < item.chapters.length) {
      final nextChapter = item.chapters[chIndex + 1];
      final (nIno, nStartOffset) = AudiobookAudioHandler.resolveFilePosition(
        files: files,
        seconds: nextChapter.start,
      );
      final (nEndIno, nEndOffset) = AudiobookAudioHandler.resolveFilePosition(
        files: files,
        seconds: nextChapter.end,
      );
      if (nIno.isNotEmpty && nEndIno == nIno) {
        nextFileIno = nIno;
        nextStartSec = nStartOffset;
        nextEndSec = nEndOffset;
      }
    }

    // Record everything the progress syncer needs for this book so it can
    // report a position on the whole-book timeline.
    _syncBookDuration = item.duration;
    _syncChapterStart = chapter.start;
    _chapterOffsetSeconds = chapterOffsetSeconds;
    _syncStartedAt = DateTime.now().millisecondsSinceEpoch;

    if (offlineBook != null) {
      final audioFile = item.audioFiles.firstWhere(
        (f) => f.ino == ino,
        orElse: () => item.audioFiles.first,
      );
      // Same naming scheme as the downloader (see AbsAudioFile.offlineFilename)
      // so a downloaded book is always found on disk for offline playback.
      final filePath = '${offlineBook.dirPath}/${audioFile.offlineFilename}';
      if (!await File(filePath).exists()) {
        // Safety net for chapter-level downloads: this file wasn't fetched
        // yet — grab just this one from ABS so playback always works.
        try {
          await ref
              .read(offlineStoreProvider.notifier)
              .downloadChapter(itemId, ino);
        } catch (_) {
          throw Exception('Audio file not on device and download failed');
        }
        if (!await File(filePath).exists()) {
          throw Exception('Local audio file missing: $filePath');
        }
      }

      // For offline playback, only attach the next chapter's prefetch
      // when the file is already on disk too — otherwise the queued
      // source would fail to open. If it's missing we just fall back to
      // a single-item playlist (no prefetch), same as before this change.
      if (nextFileIno != null) {
        final nextAudioFile = item.audioFiles.firstWhere(
          (f) => f.ino == nextFileIno,
          orElse: () => const AbsAudioFile(ino: '', duration: 0, filename: ''),
        );
        if (nextAudioFile.ino.isNotEmpty) {
          final candidate = '${offlineBook.dirPath}/${nextAudioFile.offlineFilename}';
          if (await File(candidate).exists()) {
            nextFilePath = candidate;
          }
        }
      }
      if (nextFilePath == null) {
        nextFileIno = null;
        nextStartSec = null;
        nextEndSec = null;
      }

      await handler.loadChapterFromFile(
        filePath: filePath,
        startSec: offsetInFile,
        endSec: chapterStartOffsetInFile + chapter.duration,
        title: title,
        artist: artist,
        chapterNumber: chapterNumber,
        totalChapters: totalChapters,
        nextFilePath: nextFilePath,
        nextStartSec: nextStartSec,
        nextEndSec: nextEndSec,
      );
    } else {
      await handler.loadChapter(
        absUrl: config.absUrl,
        token: config.absToken,
        itemId: itemId,
        fileIno: ino,
        startSec: offsetInFile,
        endSec: chapterStartOffsetInFile + chapter.duration,
        title: title,
        artist: artist,
        chapterNumber: chapterNumber,
        totalChapters: totalChapters,
        nextFileIno: nextFileIno,
        nextStartSec: nextStartSec,
        nextEndSec: nextEndSec,
      );
    }

    state = state.copyWith(
      isArabic: isArabic,
      audioReady: true,
      chapterDuration: chapter.duration.asDuration,
      position: chapterOffsetSeconds.asDuration,
      chapterIndex: chIndex,
      totalChapters: totalChapters,
      chapterStartInBook: chapter.start,
      bookDurationSeconds: item.duration,
    );

    // Two listeners cooperate to detect "chapter ended":
    //
    //  * currentIndexStream — fires `1` when the playlist auto-advances
    //    from index 0 (current) to index 1 (prefetched next). This is the
    //    common case: the current chapter ended and we need to rebuild
    //    the queue with [next, nextNext] so the prefetch keeps rolling.
    //  * processingStateStream — fires `completed` when the playlist
    //    exhausts its items (i.e. we're on the last chapter and the
    //    single source reached its end). Handles the "book finished"
    //    path.
    _currentIndexSub = handler.player.currentIndexStream.listen((idx) {
      if (idx == 1 && state.audioReady) _onChapterEnd(advanced: true);
    });
    _processingSub = handler.player.processingStateStream.listen((ps) {
      // The playlist rebuild sets processingState to loading/ready as it
      // swaps sources — those events must not be mistaken for chapter end.
      if (_advancingPlaylist) return;
      if (ps == ProcessingState.completed) _onChapterEnd(advanced: false);
    });
  }

  // ── VTT loading with offline cache ────────────────────────────────

  Future<void> _loadVtt(String itemId, int chapterIndex) async {
    if (!ref.read(configProvider).serverConfigured) {
      // No backend — try cache before giving up.
      final cached = _readCache(itemId, chapterIndex);
      if (cached != null) {
        _applyVtt(cached, fromCache: true);
      } else {
        state = state.copyWith(vttStatus: VttStatus.notFound);
      }
      return;
    }

    final backend = ref.read(backendClientProvider);
    try {
      final res = await backend.get('/api/vtt/$itemId/$chapterIndex');
      switch (res.statusCode) {
        case 200:
          final vtt = res.data.toString();
          await _writeCache(itemId, chapterIndex, vtt); // persist for offline
          _applyVtt(vtt, fromCache: false);
          return;

        case 202:
          // Server is still transcribing — serve cache immediately if we have
          // it so the user can read while waiting for the new version.
          final cached = _readCache(itemId, chapterIndex);
          if (cached != null) {
            _applyVtt(cached, fromCache: true);
            return;
          }
          state = state.copyWith(
            vttStatus: VttStatus.transcribing,
            transcribeProgress: _progressFrom202(res.data),
          );
          _pollVtt(itemId, chapterIndex);
          return;

        case 404:
          final cached = _readCache(itemId, chapterIndex);
          if (cached != null) {
            _applyVtt(cached, fromCache: true);
          } else {
            state = state.copyWith(vttStatus: VttStatus.notFound);
          }
          return;

        default:
          state = state.copyWith(vttStatus: VttStatus.notFound);
          return;
      }
    } catch (_) {
      // Network error (server offline / unreachable) — fall back to cache.
      // With no cache, don't give up permanently: transcription keeps
      // running server-side, so re-check once after a delay. The retry is
      // one-shot and canceled by a chapter switch / dispose / a concurrent
      // success, and re-arms itself only while the backend stays down.
      _vttRetryTimer?.cancel();
      final cached = _readCache(itemId, chapterIndex);
      if (cached != null) {
        _applyVtt(cached, fromCache: true);
      } else {
        state = state.copyWith(vttStatus: VttStatus.notFound);
        _vttRetryTimer = Timer(const Duration(seconds: 45), () {
          // Stale guard: the user may have switched chapters meanwhile.
          if (state.itemId != itemId || state.chapterIndex != chapterIndex) {
            return;
          }
          if (state.hasVtt || state.vttStatus == VttStatus.transcribing) {
            return;
          }
          unawaited(_loadVtt(itemId, chapterIndex).then((_) {
            // Successful apply (or another arm in _loadVtt's catch) has
            // already run — nothing to do here; the future just keeps
            // unhandled errors from surfacing.
          }));
        });
      }
    }
  }

  void _pollVtt(String itemId, int chapterIndex) {
    _vttPollTimer?.cancel();
    _vttPollTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
      final backend = ref.read(backendClientProvider);
      try {
        final res = await backend.get('/api/vtt/$itemId/$chapterIndex');
        if (res.statusCode == 200) {
          t.cancel();
          final vtt = res.data.toString();
          await _writeCache(itemId, chapterIndex, vtt);
          _applyVtt(vtt, fromCache: false);
        } else if (res.statusCode == 202) {
          state = state.copyWith(
            transcribeProgress: _progressFrom202(res.data),
          );
        } else if (res.statusCode == 404) {
          t.cancel();
          state = state.copyWith(
            vttStatus: VttStatus.notFound,
            transcribeProgress: 0,
          );
        }
      } catch (_) {
        // Transient network error during polling — keep polling, serve cache
        // if we haven't applied it yet.
        if (!state.hasVtt) {
          final cached = _readCache(itemId, chapterIndex);
          if (cached != null) {
            t.cancel();
            _applyVtt(cached, fromCache: true);
          }
        }
      }
    });
  }

  void _applyVtt(String vttContent, {required bool fromCache}) {
    // A transcript landed — any pending retry is obsolete.
    _vttRetryTimer?.cancel();
    final cues = VttParser.parse(vttContent);
    if (cues.isEmpty) {
      state = state.copyWith(
        vttStatus: VttStatus.notFound,
        transcribeProgress: 0,
      );
      return;
    }
    state = state.copyWith(
      vttStatus: VttStatus.ready,
      cues: cues,
      flatWords: VttParser.flattenWords(cues),
      transcribeProgress: 0,
      servedFromCache: fromCache,
    );
    _syncWord(state.position);
  }

  /// BUG FIX v1: backend sends 0.0–1.0, old code divided by 100.
  double _progressFrom202(dynamic data) {
    if (data is Map<String, dynamic>) {
      final p = data['progress'];
      if (p is num) return p.toDouble().clamp(0.0, 1.0);
    }
    return 0.0;
  }

  void _startSyncListener() {
    final handler = ref.read(audioHandlerProvider);

    _positionSub?.cancel();
    _positionSub = handler.player.positionStream.listen((raw) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _lastEmitMs < 90) return;
      _lastEmitMs = nowMs;
      // `raw` is relative to the ClippingAudioSource's own start boundary,
      // which is the resume point when we skipped ahead mid-chapter — add
      // that back so `position` stays in "seconds since chapter start"
      // terms, matching VTT cue timestamps and the scrubber/ABS-sync math.
      final position = _chapterOffsetSeconds == 0
          ? raw
          : raw + _chapterOffsetSeconds.asDuration;
      _lastPosition = position;
      state = state.copyWith(position: position);
      _syncWord(position);
      _driftSync();
    });

    // BUG FIX v1: was never listening to playingStream.
    _playingSub?.cancel();
    _playingSub = handler.player.playingStream.listen((isPlaying) {
      state = state.copyWith(playing: isPlaying);
    });
  }

  void _syncWord(Duration position) {
    final words = state.flatWords;
    if (words.isEmpty) return;
    final word = VttParser.findWordAt(position, words);
    if (word == null) {
      if (state.currentCueIndex != null) {
        state = state.copyWith(clearWord: true);
      }
      return;
    }
    if (word.cueIndex != state.currentCueIndex ||
        word.wordIndex != state.currentWordIndex) {
      state = state.copyWith(
        currentCueIndex: word.cueIndex,
        currentWordIndex: word.wordIndex,
      );
    }
  }

  // ── Local progress persistence ──────────────────────────────────────

  /// Persists the current chapter + position to local storage. No-op while
  /// nothing is loaded (no item or duration known yet). Fire-and-forget: a
  /// flurry of writes around pause/chapter-switch/dispose is harmless, and
  /// any intermediate value that gets persisted is still a valid resume
  /// point.
  void _saveLocalProgress() {
    final itemId = state.itemId;
    if (itemId == null) return;
    final durMs = state.chapterDuration.inMilliseconds;
    if (durMs <= 0) return;
    final posSec = (state.position.inMilliseconds / 1000.0).clamp(
      0.0,
      durMs / 1000.0,
    );
    unawaited(
      BookPlaybackProgress.save(
        ref.read(sharedPrefsProvider),
        itemId,
        state.chapterIndex,
        posSec,
      ),
    );
  }

  /// Best-effort final flush used on app backgrounding / dispose: writes the
  /// local store AND re-arms + fires the progress sync so the server gets
  /// the freshest position too (when reachable).
  Future<void> flushProgress() async {
    _saveLocalProgress();
    _lastSyncMs = 0;
    _syncProgress();
  }

  // ── Progress-server sync ────────────────────────────────────────────

  /// Throttled rolling sync — fires at most once per `_backoffSeconds()` while
  /// playing so we don't hammer the server, but still keeps ABS up to date.
  /// After a transient failure the throttle backs off (10s → 30s → 60s → …
  /// capped at 5m) and retries, so sync self-recovers when the server comes
  /// back.
  void _driftSync() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final backoffMs = 1000 * _backoffSeconds();
    if (nowMs - _lastSyncMs < backoffMs) return;
    _lastSyncMs = nowMs;
    _syncProgress();
  }

  /// Seconds to wait before the next retry after [_syncFailures] consecutive
  /// failures. Exponential with a 5-minute cap; resets on success.
  int _backoffSeconds() {
    if (_syncFailures <= 0) return 10;
    final exp = 10 * (1 << (_syncFailures - 1).clamp(0, 5));
    return exp.clamp(10, 300);
  }

  /// Reports the current book-timeline position to the metadata server.
  void _syncProgress({bool isFinished = false}) {
    final itemId = _syncItemId;
    if (itemId == null) return;
    final duration = _syncBookDuration;
    if (duration <= 0) return;

    // Player position is inside the chapter clip; chapter.start is the
    // chapter's offset on the whole-book timeline.
    final positionSec = _lastPosition.inMilliseconds / 1000.0;
    final currentTime =
        (_syncChapterStart + positionSec).clamp(0.0, duration);
    final chapterIndex = state.chapterIndex;

    unawaited(
      ref
          .read(progressSyncProvider)
          .bookProgress(
            itemId: itemId,
            chapterIndex: chapterIndex,
            positionSec: positionSec,
            progressFraction: (currentTime / duration).clamp(0.0, 1.0),
          )
          .then((accepted) {
            if (accepted) {
              _syncFailures = 0;
              _lastSyncMs = DateTime.now().millisecondsSinceEpoch;
              return;
            }
            // Transient failure (offline, server down) — bump the backoff so
            // we don't hammer, then retry on a later tick.
            _syncFailures++;
            _lastSyncMs = DateTime.now().millisecondsSinceEpoch;
          }),
    );

    // Whole-book finished flag — fires on book completion so the server
    // (and therefore other devices after their login restore) sees it.
    if (isFinished) {
      unawaited(
        ref.read(progressSyncProvider).bookFinished(itemId, true),
      );
    }

    // Mirror the within-chapter position to the progress server too — the
    // whole-book bookmark alone only resumes at the chapter boundary on a
    // fresh install. Locally dedup'd (>0.5s change) and in-flight-dedup'd
    // inside the provider, so it's safe to fire from every sync tick
    // (throttled play ticks + immediate pause/seek/chapter-change).
    if (positionSec > 0 && chapterIndex >= 0) {
      unawaited(
        ref
            .read(readChaptersProvider.notifier)
            .recordChapterPosition(itemId, chapterIndex, positionSec),
      );
    }
  }

  // ── Playback controls ──────────────────────────────────────────────

  Future<void> togglePlayPause() async {
    final handler = ref.read(audioHandlerProvider);
    if (handler.player.playing) {
      await handler.pause();
      // Flush progress immediately on pause so the progress server and the
      // local store both see where we stopped.
      _saveLocalProgress();
      _lastSyncMs = 0;
      _syncProgress();
    } else {
      if (_syncStartedAt == 0) {
        _syncStartedAt = DateTime.now().millisecondsSinceEpoch;
      }
      await handler.play();
    }
  }

  Future<void> seekTo(Duration d) {
    // A manual seek changed the position — sync it on the next tick.
    _lastSyncMs = 0;
    // Inverse of the position-listener adjustment above: `d` comes in as
    // "seconds since chapter start" (what the scrubber shows), but the
    // underlying ClippingAudioSource needs a position relative to its own
    // start boundary — subtract back out the resume offset, if any.
    final clipRelative = _chapterOffsetSeconds == 0
        ? d
        : d - _chapterOffsetSeconds.asDuration;
    return ref
        .read(audioHandlerProvider)
        .seek(clipRelative.isNegative ? Duration.zero : clipRelative);
  }

  /// Seeks against the whole-book timeline (the top/overall slider in
  /// chapter_scrubber.dart), switching chapters first if [targetSeconds]
  /// lands outside the currently-loaded chapter.
  Future<void> seekToBookPosition(double targetSeconds) async {
    final itemId = state.itemId;
    if (itemId == null) return;
    final meta = ref.read(bookMetaProvider(itemId)).valueOrNull;
    if (meta == null || meta.chapters.isEmpty) return;
    final target = meta.chapterForBookPosition(targetSeconds);
    if (target.chapterIndex == state.chapterIndex) {
      await seekTo(target.offsetSeconds.asDuration);
    } else {
      await switchChapter(target.chapterIndex);
      await seekTo(target.offsetSeconds.asDuration);
    }
  }

  Future<void> skipForward15() =>
      ref.read(audioHandlerProvider).skipForward15();
  Future<void> skipForward30() =>
      ref.read(audioHandlerProvider).skipForward30();
  Future<void> skipBackward15() =>
      ref.read(audioHandlerProvider).skipBackward15();

  Future<void> setSpeed(double speed) async {
    await ref.read(audioHandlerProvider).setSpeed(speed);
    state = state.copyWith(speed: speed);
    await ref.read(sharedPrefsProvider).setDouble(kPlaybackSpeedKey, speed);
  }

  /// Enters/exits immersive read-along mode. The system-bar transitions and
  /// layout collapse live in PlayerScreen's build; this just flips the flag.
  Future<void> setFullscreenReader(bool on) async {
    if (state.fullscreenReader == on) return;
    state = state.copyWith(fullscreenReader: on);
  }

  Future<void> cycleSpeed() async {
    const speeds = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0];
    final idx = speeds.indexOf(state.speed);
    final next = speeds[(idx + 1) % speeds.length];
    await setSpeed(next);
  }

  /// Nudges the current playback speed up/down for the − / + steppers,
  /// clamped to the same bounds as the fine-control sheet (0.5×–3.0×) and
  /// rounded to the sheet's 0.05× step so the slider/presets stay in sync.
  Future<void> adjustSpeed(double delta) async {
    final next = (state.speed + delta).clamp(0.5, 3.0);
    await setSpeed((next * 20).round() / 20);
  }

  Future<void> switchChapter(int newIndex) async {
    final itemId = state.itemId;
    if (itemId == null) return;
    final old = state;
    // Skip-in-circles protection: clamped in prev/next below.
    final clamped = newIndex.clamp(0, old.totalChapters - 1);
    if (clamped != newIndex) return;
    // A chapter switch makes the pending VTT retry (and any transcribe
    // polling) obsolete — the new chapter loads its own.
    _vttRetryTimer?.cancel();
    // Mark the departed chapter as listened so the read-along "read so far"
    // stays truthful about skipping around:
    //  * jumping FORWARD past a chapter = you chose not to hear it,
    //  * jumping BACKWARD = you "un-hear" the tail of the book only if you
    //    had actually played most of it (>= 90%) — otherwise the mark would
    //    instantly defeat a half-heard chapter's badge.
    final meta = ref.read(bookMetaProvider(itemId)).valueOrNull;
    if (meta != null && meta.chapters.isNotEmpty) {
      final notifier = ref.read(readChaptersProvider.notifier);
      if (clamped > old.chapterIndex) {
        for (var i = old.chapterIndex; i < clamped; i++) {
          notifier.markListened(itemId, i);
        }
      } else if (clamped < old.chapterIndex &&
          old.chapterDuration > Duration.zero &&
          old.position.inMilliseconds >=
              old.chapterDuration.inMilliseconds * 0.9) {
        notifier.markListened(itemId, old.chapterIndex);
      }
    }
    // Persist where the previous chapter left off, both locally and (when
    // reachable) on the progress server.
    _saveLocalProgress();
    _lastSyncMs = 0;
    _syncProgress();
    _vttPollTimer?.cancel();
    _progressTimer?.cancel();
    state = const PlayerState();
    _loadedChapterIndex = -1;
    await init(itemId, clamped);
    await ref.read(audioHandlerProvider).play();
  }

  Future<void> restart() async {
    if (state.itemId == null) return;
    await switchChapter(0);
  }

  /// Next chapter. No-op on the last chapter (the row's next button can't
  /// wrap into a "start over" accident).
  Future<void> nextChapter() {
    if (state.isOnLastChapter) return Future.value();
    return switchChapter(state.chapterIndex + 1);
  }

  /// Previous chapter: rewind to the top of the current one, one chapter
  /// per press from there — the classic podcast-app behaviour.
  Future<void> prevChapter() {
    if (state.chapterIndex <= 0) {
      return seekTo(Duration.zero);
    }
    return switchChapter(state.chapterIndex - 1);
  }

  void _onChapterEnd({required bool advanced}) {
    // Mark the chapter that just finished.
    final itemId = state.itemId;
    if (itemId != null) {
      ref
          .read(readChaptersProvider.notifier)
          .markListened(itemId, state.chapterIndex);
    }

    if (state.sleepTimer == SleepTimerState.endOfChapter) {
      _lastSyncMs = 0;
      _syncProgress();
      setSleepTimer(SleepTimerState.off);
      return;
    }
    if (state.isOnLastChapter) {
      // Mark the whole book as finished on the progress server too. `advanced == false`
      // here means the playlist exhausted (single source, last chapter);
      // `advanced == true` would be unusual at this point because we
      // never queue a "next" past the last chapter, but guard anyway.
      _syncProgress(isFinished: true);
      state = state.copyWith(playing: false, finished: true);
      return;
    }
    if (!advanced) return; // single-item playlist ended cleanly; nothing to do
    if (state.audioReady) {
      // Auto-advanced into the prefetched next chapter. Rebuild the
      // queue so the now-current chapter sits at index 0 with its own
      // prefetch (nextNext) at index 1 — the prefetch chain keeps rolling.
      //
      // CRITICAL: this is running inside a player stream listener. Calling
      // setAudioSources() synchronously from within that listener deadlocks
      // just_audio's event pump (the load waits for events that can't be
      // delivered until the listener returns) — the app freezes and then
      // dies. Defer the rebuild to the next event-loop turn. A reentrancy
      // guard additionally collapses duplicate end-of-chapter events
      // (idx==1 firing again, or `completed` during the rebuild) into a
      // single rebuild — two concurrent setAudioSources calls crash.
      _advancingPlaylist = true;
      Timer.run(() async {
        try {
          await _advancePlaylist();
        } finally {
          _advancingPlaylist = false;
        }
      });
    }
  }

  /// True while the end-of-chapter playlist rebuild is queued/in flight.
  /// Collapses the burst of end-of-chapter events (currentIndexStream's
  /// idx==1 plus processingStateStream's `completed`, plus any events the
  /// rebuild itself emits) into a single [ _advancePlaylist ] run.
  bool _advancingPlaylist = false;
  /// Set while [ _advancePlaylist ]'s body is actually executing — used
  /// together with [_advancingPlaylist] to drop requests that arrive while
  /// a rebuild is already running (double setAudioSources = crash).
  bool _playlistAdvanceRunning = false;

  /// Rebuilds the just_audio playlist so the chapter we just auto-advanced
  /// into sits at index 0, with its own successor at index 1 — so the
  /// prefetch chain keeps rolling. Uses [state.chapterIndex] + 1 as the
  /// new current, + 2 as the new prefetch.
  Future<void> _advancePlaylist() async {
    if (_advancingPlaylist && _playlistAdvanceRunning) return;
    _playlistAdvanceRunning = true;
    try {
      final item = _loadedItem;
    if (item == null) return;
    final handler = ref.read(audioHandlerProvider);
    final nextIdx = state.chapterIndex + 1;
    if (nextIdx >= item.chapters.length) return;
    final config = ref.read(configProvider);
    final offlineBook = ref.read(offlineStoreProvider).books[item.id];
    final files = item.audioFiles
        .map((f) => (ino: f.ino, duration: f.duration))
        .toList();

    Future<({String? fileIno, double startSec, double endSec, String? filePath})>
        resolveClipBounds(int chIdx) async {
      const empty = (fileIno: null, startSec: 0.0, endSec: 0.0, filePath: null);
      if (chIdx >= item.chapters.length) return empty;
      final ch = item.chapters[chIdx];
      final (ino, startOffset) = AudiobookAudioHandler.resolveFilePosition(
        files: files,
        seconds: ch.start,
      );
      final (endIno, endOffset) = AudiobookAudioHandler.resolveFilePosition(
        files: files,
        seconds: ch.end,
      );
      // Skip prefetch for chapters that span files (can't be expressed
      // as a single ClippingAudioSource).
      if (ino.isEmpty || endIno != ino) return empty;
      String? filePath;
      if (offlineBook != null) {
        final af = item.audioFiles.firstWhere(
          (f) => f.ino == ino,
          orElse: () => const AbsAudioFile(ino: '', duration: 0, filename: ''),
        );
        if (af.ino.isEmpty) return empty;
        final p = '${offlineBook.dirPath}/${af.offlineFilename}';
        if (await File(p).exists()) {
          filePath = p;
        } else {
          return empty;
        }
      }
      return (fileIno: ino, startSec: startOffset, endSec: endOffset, filePath: filePath);
    }

    final current = await resolveClipBounds(nextIdx);
    final prefetch = await resolveClipBounds(nextIdx + 1);
    if (current.fileIno == null) return; // can't even queue the current chapter

    final sources = <AudioSource>[
      _buildChapterSource(item.id, config, current, isOffline: offlineBook != null),
      if (prefetch.fileIno != null)
        _buildChapterSource(
            item.id, config, prefetch, isOffline: offlineBook != null),
    ];

    await handler.player.setAudioSources(
      sources,
      initialIndex: 0,
      initialPosition: Duration.zero,
    );

    // Update state + sync bookkeeping for the new current chapter.
    final nextChapter = item.chapters[nextIdx];
    _syncChapterStart = nextChapter.start;
    _chapterOffsetSeconds = 0;
    _syncStartedAt = DateTime.now().millisecondsSinceEpoch;
    _lastPosition = Duration.zero;
    _lastEmitMs = 0;
    state = state.copyWith(
      chapterIndex: nextIdx,
      chapterDuration: nextChapter.duration.asDuration,
      position: Duration.zero,
      chapterStartInBook: nextChapter.start,
      // The transcript cues/word-cursor belong to the previous chapter —
      // clear them here (the async VTT load below replaces them). Leaving
      // the old cues in place made _syncWord highlight stale cues and the
      // reading view fight the chapter transition at the boundary.
      clearWord: true,
    );

    // Load the new chapter's transcript. The old chapter's VTT (with its
    // stale cue list and word cursor) must not carry over — the reading
    // view rebuilds its auto-scroll bookkeeping off the cue-count change,
    // which only happens once the new VTT lands.
    unawaited(_loadVtt(item.id, nextIdx).then((_) {
      if (state.vttStatus == VttStatus.ready) _syncWord(state.position);
    }));
    } finally {
      _playlistAdvanceRunning = false;
    }
  }

  /// Builds a single chapter's [AudioSource] — either a clipped URL
  /// source (streaming) or a clipped file source (offline). The clip
  /// window is what makes the player stop exactly at chapter end and
  /// trigger the auto-advance to the queued next chapter.
  AudioSource _buildChapterSource(
    String itemId,
    AppConfig config,
    ({String? fileIno, double startSec, double endSec, String? filePath}) clip, {
    required bool isOffline,
  }) {
    final ino = clip.fileIno!;
    final start = Duration(milliseconds: (clip.startSec * 1000).toInt());
    final end = Duration(milliseconds: (clip.endSec * 1000).toInt());
    if (isOffline) {
      return ClippingAudioSource(
        child: AudioSource.uri(Uri.file(clip.filePath!)),
        start: start,
        end: end,
      );
    }
    return ClippingAudioSource(
      child: AudioSource.uri(
        Uri.parse('${config.absUrl}/api/items/$itemId/file/$ino'),
        headers: {'Authorization': 'Bearer ${config.absToken}'},
      ),
      start: start,
      end: end,
    );
  }

  // ── Sleep timer ────────────────────────────────────────────────────

  void setSleepTimer(SleepTimerState s) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    state = state.copyWith(sleepTimer: s);
    if (s == SleepTimerState.min30 || s == SleepTimerState.min60) {
      _sleepTimer = Timer(
        s == SleepTimerState.min30
            ? const Duration(minutes: 30)
            : const Duration(minutes: 60),
        () async {
          await ref.read(audioHandlerProvider).pause();
          _lastSyncMs = 0;
          _syncProgress();
          state = state.copyWith(sleepTimer: SleepTimerState.off);
        },
      );
    }
  }

  // ── Font size ──────────────────────────────────────────────────────

  Future<void> changeFontSize(double delta) async {
    final newSize = (state.readingFontSize + delta).clamp(16.0, 34.0);
    state = state.copyWith(readingFontSize: newSize);
    await ref.read(sharedPrefsProvider).setDouble('reading_font_size', newSize);
  }

  Future<bool> transcribeCurrentChapter() async {
    final itemId = state.itemId;
    if (itemId == null) return false;
    if (!ref.read(configProvider).serverConfigured) return false;
    final backend = ref.read(backendClientProvider);
    try {
      final res = await backend.post(
        '/api/transcribe',
        data: {
          'abs_item_id': itemId,
          'mode': 'chapter',
          'chapter_index': state.chapterIndex,
        },
      );
      final code = res.statusCode ?? 500;
      final ok = code == 202 || code < 300;
      if (ok) {
        state = state.copyWith(vttStatus: VttStatus.transcribing);
        _pollVtt(itemId, state.chapterIndex);
      }
      return ok;
    } catch (_) {
      return false;
    }
  }
}

final playerProvider = NotifierProvider<PlayerController, PlayerState>(
  PlayerController.new,
);
