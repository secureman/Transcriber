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
  String? _syncMediaId;
  double _syncBookDuration = 0;
  double _syncChapterStart = 0;
  int _syncStartedAt = 0;
  Duration _lastPosition = Duration.zero;
  List<Map<String, dynamic>> _syncAudioTracks = const [];
  Map<String, dynamic>? _syncLibraryItem;
  bool _syncDisabled = false;
  int _syncFailures = 0;
  int _lastSyncMs = 0;

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
    // Best-effort final progress flush when leaving the player / app.
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
    _syncMediaId = null;
    _syncBookDuration = 0;
    _syncChapterStart = 0;
    _syncDisabled = false;
    _syncFailures = 0;
    _lastSyncMs = 0;

    final prefs = ref.read(sharedPrefsProvider);
    final lastSize = prefs.getDouble('reading_font_size') ?? 22;

    state = PlayerState(
      itemId: itemId,
      chapterIndex: chapterIndex,
      vttStatus: VttStatus.loading,
      readingFontSize: lastSize,
    );

    // BUG FIX v1: catch audio errors so VTT still loads.
    await Future.wait([
      _loadAudio(itemId, chapterIndex).catchError((Object e) {}),
      _loadVtt(itemId, chapterIndex),
    ]);

    _startSyncListener();
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
      final res = await abs.get('/api/items/$itemId');
      if (res.statusCode != 200) {
        throw Exception('Failed to load item (HTTP ${res.statusCode})');
      }
      item = AbsItem.fromJson(res.data as Map<String, dynamic>);
    }

    final isArabic =
        item.isArabic || (item.language?.toLowerCase().startsWith('ar') ?? false);

    if (item.chapters.isEmpty || item.audioFiles.isEmpty) {
      throw Exception('Book has no chapters or audio files');
    }

    final chIndex = chapterIndex.clamp(0, item.chapters.length - 1);
    final chapter = item.chapters[chIndex];
    final totalChapters = item.chapters.length;

    final files = item.audioFiles
        .map((f) => (ino: f.ino, duration: f.duration))
        .toList();
    final (ino, offsetInFile) = AudiobookAudioHandler.resolveFilePosition(
      files: files,
      seconds: chapter.start,
    );

    final title = item.title;
    final artist = item.author.isEmpty ? null : item.author;
    final chapterNumber = chIndex + 1;

    // Record everything the ABS progress syncer needs for this book so it can
    // report a position on the whole-book timeline.
    _syncMediaId = item.mediaId.isEmpty ? null : item.mediaId;
    _syncBookDuration = item.duration;
    _syncChapterStart = chapter.start;
    _syncStartedAt = DateTime.now().millisecondsSinceEpoch;
    _syncAudioTracks = [
      for (var i = 0; i < item.audioFiles.length; i++)
        buildAudioTrack(
          index: i,
          filename: item.audioFiles[i].filename,
          url: '${config.absUrl}/api/items/$itemId/file/${item.audioFiles[i].ino}',
        ),
    ];
    _syncLibraryItem = buildMinifiedLibraryItem(item);

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
        endSec: offsetInFile + chapter.duration,
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
        endSec: offsetInFile + chapter.duration,
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
      position: Duration.zero,
      chapterIndex: chIndex,
      totalChapters: totalChapters,
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
      state = state.copyWith(vttStatus: VttStatus.notFound, transcribeProgress: 0);
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
    _positionSub = handler.player.positionStream.listen((position) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _lastEmitMs < 90) return;
      _lastEmitMs = nowMs;
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
      if (state.currentCueIndex != null) state = state.copyWith(clearWord: true);
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

  // ── ABS progress sync ──────────────────────────────────────────────

  /// Throttled rolling sync — fires at most once per 10s while playing so we
  /// don't hammer the server, but still keeps ABS up to date.
  void _driftSync() {
    if (_syncDisabled) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastSyncMs < 10000) return;
    _lastSyncMs = nowMs;
    _syncProgress();
  }

  /// Reports the current book-timeline position to Audiobookshelf.
  void _syncProgress({bool isFinished = false}) {
    if (_syncDisabled) return;
    final itemId = _syncItemId;
    final mediaId = _syncMediaId;
    if (itemId == null || mediaId == null || mediaId.isEmpty) return;
    final duration = _syncBookDuration;
    if (duration <= 0 || _syncLibraryItem == null) return;

    // Player position is inside the chapter clip; chapter.start is the
    // chapter's offset on the whole-book timeline.
    final currentTime =
        (_syncChapterStart + _lastPosition.inMilliseconds / 1000.0)
            .clamp(0.0, duration);

    unawaited(
      ref
          .read(progressSyncProvider)
          .reportProgress(
            itemId: itemId,
            mediaId: mediaId,
            durationSec: duration,
            currentTimeSec: currentTime,
            isFinished: isFinished,
            startedAt: _syncStartedAt,
            finishedAt: isFinished
                ? DateTime.now().millisecondsSinceEpoch
                : null,
            audioTracks: _syncAudioTracks,
            libraryItem: _syncLibraryItem,
          )
          .then((accepted) {
            if (accepted) {
              _syncFailures = 0;
              return;
            }
            // Two consecutive failures (offline, bad token, unsupported ABS)
            // → stop trying until the next book is opened.
            _syncFailures++;
            if (_syncFailures >= 2) {
              _syncDisabled = true;
              _syncFailures = 0;
            }
            _lastSyncMs = 0; // retry on next tick instead of waiting 10s
          }),
    );
  }

  // ── Playback controls ──────────────────────────────────────────────

  Future<void> togglePlayPause() async {
    final handler = ref.read(audioHandlerProvider);
    if (handler.player.playing) {
      await handler.pause();
      // Flush progress immediately on pause so ABS sees where we stopped.
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
    return ref.read(audioHandlerProvider).seek(d);
  }
  Future<void> skipForward15() => ref.read(audioHandlerProvider).skipForward15();
  Future<void> skipBackward15() => ref.read(audioHandlerProvider).skipBackward15();

  Future<void> setSpeed(double speed) async {
    await ref.read(audioHandlerProvider).setSpeed(speed);
    state = state.copyWith(speed: speed);
  }

  Future<void> cycleSpeed() async {
    const speeds = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0];
    final idx = speeds.indexOf(state.speed);
    final next = speeds[(idx + 1) % speeds.length];
    await setSpeed(next);
  }

  Future<void> switchChapter(int newIndex) async {
    final itemId = state.itemId;
    if (itemId == null) return;
    // Persist where the previous chapter left off.
    _lastSyncMs = 0;
    _syncProgress();
    _vttPollTimer?.cancel();
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
      ref.read(readChaptersProvider.notifier)
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
      final res = await backend.post('/api/transcribe', data: {
        'abs_item_id': itemId,
        'mode': 'chapter',
        'chapter_index': state.chapterIndex,
      });
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

final playerProvider =
    NotifierProvider<PlayerController, PlayerState>(PlayerController.new);
