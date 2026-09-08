import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import '../../core/network/abs_client.dart';
import '../../core/network/abs_sync.dart';
import '../../core/network/backend_client.dart';
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
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<ProcessingState>? _processingSub;
  // BUG FIX v1: track playing state so play/pause button reflects reality.
  StreamSubscription<bool>? _playingSub;
  int _lastEmitMs = 0;
  int _loadedChapterIndex = -1;

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
    _loadedChapterIndex = chapterIndex;

    // Fresh ABS sync context for this book.
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
    // Previously this always seeked to chapter.start, even though the
    // exact position was being faithfully pushed to ABS the whole time via
    // _syncProgress() — a write-only relationship with the server. ABS's
    // userMediaProgress.currentTime (only present when fetched with
    // ?expanded=1, see AbsItem.fromJson) is the live, cross-device source
    // of truth for "where did the user actually stop". We only apply it
    // when it falls inside the chapter we're about to load — if it
    // doesn't, this is ordinary chapter navigation (next/prev/tapped a
    // different chapter), not a resume, and it should start at the top
    // like before. Because the exact-second position is synced to ABS
    // continuously as the book is played, a stale/previous chapter's
    // progress value naturally won't fall in an unrelated chapter's
    // range, so this check doesn't need any extra "is this the first
    // load of the session" bookkeeping to stay correct.
    final resumeTarget = item.resumeSeconds;
    double seekSeconds;
    if (resumeTarget != null &&
        resumeTarget >= chapter.start &&
        resumeTarget < chapter.end) {
      // ABS is the freshest cross-device source of truth — prefer it.
      seekSeconds = resumeTarget;
    } else {
      // No usable ABS resume point (fresh book, sync disabled/stale after
      // a failed write, server unreachable) — fall back to this app's
      // locally persisted position, but only when it belongs to the chapter
      // we're actually loading. If it belongs to a different chapter (user
      // tapped a chapter from the list), start at that chapter's top as
      // usual.
      final localProgress = BookPlaybackProgress.fromPrefs(
        ref.read(sharedPrefsProvider),
        itemId,
      );
      if (localProgress != null &&
          localProgress.chapterIndex == chIndex &&
          localProgress.positionSeconds > 0 &&
          localProgress.positionSeconds < chapter.duration) {
        seekSeconds = chapter.start + localProgress.positionSeconds;
      } else {
        seekSeconds = chapter.start;
      }
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

    // Record everything the ABS progress syncer needs for this book so it can
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
      await handler.loadChapterFromFile(
        filePath: filePath,
        startSec: offsetInFile,
        endSec: chapterStartOffsetInFile + chapter.duration,
        title: title,
        artist: artist,
        chapterNumber: chapterNumber,
        totalChapters: totalChapters,
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

    _processingSub = handler.player.processingStateStream.listen((ps) {
      if (ps == ProcessingState.completed) _onChapterEnd();
    });
  }

  // ── VTT loading with offline cache ────────────────────────────────

  Future<void> _loadVtt(String itemId, int chapterIndex) async {
    if (!ref.read(configProvider).backendConfigured) {
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
      final cached = _readCache(itemId, chapterIndex);
      if (cached != null) {
        _applyVtt(cached, fromCache: true);
      } else {
        state = state.copyWith(vttStatus: VttStatus.notFound);
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
  /// local store AND re-arms + fires the ABS sync so the server gets the
  /// freshest position too (when reachable).
  Future<void> flushProgress() async {
    _saveLocalProgress();
    _lastSyncMs = 0;
    _syncProgress();
  }

  // ── ABS progress sync ──────────────────────────────────────────────

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

  /// Reports the current book-timeline position to Audiobookshelf.
  void _syncProgress({bool isFinished = false}) {
    final itemId = _syncItemId;
    if (itemId == null) return;
    final duration = _syncBookDuration;
    if (duration <= 0) return;

    // Player position is inside the chapter clip; chapter.start is the
    // chapter's offset on the whole-book timeline.
    final currentTime =
        (_syncChapterStart + _lastPosition.inMilliseconds / 1000.0).clamp(
          0.0,
          duration,
        );

    unawaited(
      ref
          .read(progressSyncProvider)
          .reportProgress(
            itemId: itemId,
            durationSec: duration,
            currentTimeSec: currentTime,
            isFinished: isFinished,
            startedAt: _syncStartedAt,
            finishedAt: isFinished
                ? DateTime.now().millisecondsSinceEpoch
                : null,
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
  }

  // ── Playback controls ──────────────────────────────────────────────

  Future<void> togglePlayPause() async {
    final handler = ref.read(audioHandlerProvider);
    if (handler.player.playing) {
      await handler.pause();
      // Flush progress immediately on pause so ABS and the local store both
      // see where we stopped.
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
    // Persist where the previous chapter left off, both locally and (when
    // reachable) to ABS.
    _saveLocalProgress();
    _lastSyncMs = 0;
    _syncProgress();
    _vttPollTimer?.cancel();
    _progressTimer?.cancel();
    state = const PlayerState();
    _loadedChapterIndex = -1;
    await init(itemId, newIndex);
    await ref.read(audioHandlerProvider).play();
  }

  Future<void> restart() async {
    if (state.itemId == null) return;
    await switchChapter(0);
  }

  Future<void> nextChapter() => switchChapter(state.chapterIndex + 1);
  Future<void> prevChapter() => switchChapter(state.chapterIndex - 1);

  void _onChapterEnd() {
    // Persist the "listened" flag for this chapter.
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
      // Mark the whole book as finished in ABS too.
      _syncProgress(isFinished: true);
      state = state.copyWith(playing: false, finished: true);
      return;
    }
    if (state.audioReady) nextChapter();
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
    if (!ref.read(configProvider).backendConfigured) return false;
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
