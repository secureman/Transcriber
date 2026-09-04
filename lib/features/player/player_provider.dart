import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import '../../core/network/abs_client.dart';
import '../../core/network/backend_client.dart';
import '../../core/providers/config_provider.dart';
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
  // BUG FIX: the previous version added a new `processingStateStream.listen`
  // on every `_loadAudio` call without cancelling the previous one. After
  // N chapter skips you had N listeners all firing `_onChapterEnd` on
  // completion → cascading skips. Now we keep exactly one.
  StreamSubscription<ProcessingState>? _processingSub;
  // BUG FIX: track playing state so the play/pause button reflects reality.
  StreamSubscription<bool>? _playingSub;
  int _lastEmitMs = 0;
  int _loadedChapterIndex = -1;

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
  }

  /// Entry point: loads chapter audio and VTT in parallel.
  /// Audio never waits for VTT.
  Future<void> init(String itemId, int chapterIndex) async {
    // BUG FIX: added `state.audioReady` to the guard so a failed audio load
    // doesn't permanently block retries (previously, state.itemId was set
    // before _loadAudio ran, so the guard fired on the next init() call and
    // the audio stayed broken forever).
    if (state.itemId == itemId &&
        _loadedChapterIndex == chapterIndex &&
        state.audioReady) return;

    _vttPollTimer?.cancel();
    _positionSub?.cancel();
    _processingSub?.cancel();
    _playingSub?.cancel();
    _loadedChapterIndex = chapterIndex;

    final prefs = ref.read(sharedPrefsProvider);
    final lastSize = prefs.getDouble('reading_font_size') ?? 22;

    state = PlayerState(
      itemId: itemId,
      chapterIndex: chapterIndex,
      vttStatus: VttStatus.loading,
      readingFontSize: lastSize,
    );

    // BUG FIX: _loadAudio exceptions were propagating through Future.wait and
    // getting silently swallowed by the unawaited addPostFrameCallback call.
    // That left the player with chapterDuration=0 and audioReady=false while
    // the VTT still showed (since _loadVtt catches its own errors). Now we
    // catch audio errors here so the rest of the player still works and the
    // user can at least read the transcript even if audio fails.
    await Future.wait([
      _loadAudio(itemId, chapterIndex).catchError((Object e) {
        // Audio failed: keep audioReady=false so controls stay disabled.
        // VTT loading continues unaffected.
      }),
      _loadVtt(itemId, chapterIndex),
    ]);

    _startSyncListener();
    await saveLastPlayedChapter(prefs, itemId, chapterIndex);
  }

  Future<void> _loadAudio(String itemId, int chapterIndex) async {
    final config = ref.read(configProvider);
    final handler = ref.read(audioHandlerProvider);
    final abs = ref.read(absClientProvider);

    final res = await abs.get('/api/items/$itemId');
    if (res.statusCode != 200) {
      throw Exception('Failed to load item (HTTP ${res.statusCode})');
    }
    final item = AbsItem.fromJson(res.data as Map<String, dynamic>);

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

    await handler.loadChapter(
      absUrl: config.absUrl,
      token: config.absToken,
      itemId: itemId,
      fileIno: ino,
      startSec: offsetInFile,
      endSec: offsetInFile + chapter.duration,
      title: item.title,
      artist: item.author.isEmpty ? null : item.author,
      chapterNumber: chIndex + 1,
      totalChapters: totalChapters,
    );

    state = state.copyWith(
      isArabic: isArabic,
      audioReady: true,
      chapterDuration: chapter.duration.asDuration,
      position: Duration.zero,
      chapterIndex: chIndex,
      totalChapters: totalChapters,
    );

    // Single subscription, cancellable on next chapter load. See _cleanup.
    _processingSub = handler.player.processingStateStream.listen((ps) {
      if (ps == ProcessingState.completed) _onChapterEnd();
    });
  }


  Future<void> _loadVtt(String itemId, int chapterIndex) async {
    // Without a transcription backend there is no text to show.
    if (!ref.read(configProvider).backendConfigured) {
      state = state.copyWith(vttStatus: VttStatus.notFound);
      return;
    }
    final backend = ref.read(backendClientProvider);
    try {
      final res = await backend.get('/api/vtt/$itemId/$chapterIndex');
      switch (res.statusCode) {
        case 200:
          _applyVtt(res.data.toString());
          return;
        case 202:
          state = state.copyWith(
            vttStatus: VttStatus.transcribing,
            transcribeProgress:
                _progressFrom202(res.data),
          );
          _pollVtt(itemId, chapterIndex);
          return;
        default:
          state = state.copyWith(vttStatus: VttStatus.notFound);
          return;
      }
    } catch (_) {
      state = state.copyWith(vttStatus: VttStatus.notFound);
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
          _applyVtt(res.data.toString());
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
        // 202 → keep polling
      } catch (_) {
        // transient network error → keep polling
      }
    });
  }

  void _applyVtt(String vttContent) {
    final cues = VttParser.parse(vttContent);
    if (cues.isEmpty) {
      state = state.copyWith(
          vttStatus: VttStatus.notFound, transcribeProgress: 0);
      return;
    }
    state = state.copyWith(
      vttStatus: VttStatus.ready,
      cues: cues,
      flatWords: VttParser.flattenWords(cues),
      transcribeProgress: 0,
    );
    _syncWord(state.position);
  }

  /// Parses the 202 body {"status": "processing", "progress": 0..1}.
  ///
  /// BUG FIX: the backend job_runner stores progress as a 0.0–1.0 float
  /// (e.g. 0.15 for 15%), NOT a 0–100 integer. The old code divided by 100,
  /// so 15% progress showed as 0.15% on the progress bar.
  double _progressFrom202(dynamic data) {
    if (data is Map<String, dynamic>) {
      final p = data['progress'];
      if (p is num) {
        return p.toDouble().clamp(0.0, 1.0);
      }
    }
    return 0.0;
  }

  void _startSyncListener() {
    final handler = ref.read(audioHandlerProvider);

    _positionSub?.cancel();
    _positionSub = handler.player.positionStream.listen((position) {
      // Throttle to ~100ms to limit provider rebuilds.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _lastEmitMs < 90) return;
      _lastEmitMs = nowMs;
      state = state.copyWith(position: position);
      _syncWord(position);
    });

    // BUG FIX: the old code never listened to playingStream, so state.playing
    // was always false. The play button always showed ▶ even while the audio
    // was playing, and the ⏸ icon never appeared.
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


  // ── Playback controls ──────────────────────────────────────────────

  Future<void> togglePlayPause() async {
    final handler = ref.read(audioHandlerProvider);
    if (handler.player.playing) {
      await handler.pause();
    } else {
      await handler.play();
    }
  }

  Future<void> seekTo(Duration d) => ref.read(audioHandlerProvider).seek(d);

  Future<void> skipForward15() =>
      ref.read(audioHandlerProvider).skipForward15();

  Future<void> skipBackward15() =>
      ref.read(audioHandlerProvider).skipBackward15();

  Future<void> setSpeed(double speed) async {
    await ref.read(audioHandlerProvider).setSpeed(speed);
    state = state.copyWith(speed: speed);
  }

  /// Cycles 0.75 → 0.9 → 1.0 → 1.1 → 1.25 → 1.5 → 2.0 → 0.75
  Future<void> cycleSpeed() async {
    const speeds = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0];
    final idx = speeds.indexOf(state.speed);
    final next = speeds[(idx + 1) % speeds.length];
    await setSpeed(next);
  }

  /// Loads another chapter by re-initializing the provider.
  Future<void> switchChapter(int newIndex) async {
    final itemId = state.itemId;
    if (itemId == null) return;
    _vttPollTimer?.cancel();
    state = const PlayerState();
    _loadedChapterIndex = -1;
    await init(itemId, newIndex);
    await ref.read(audioHandlerProvider).play();
  }

  /// Restart the book from chapter 0. Used after the "End of book" state
  /// is reached and the user wants to go again.
  Future<void> restart() async {
    if (state.itemId == null) return;
    await switchChapter(0);
  }

  Future<void> nextChapter() => switchChapter(state.chapterIndex + 1);

  Future<void> prevChapter() => switchChapter(state.chapterIndex - 1);

  void _onChapterEnd() {
    // Sleep "end of chapter": stop here and cancel the timer.
    if (state.sleepTimer == SleepTimerState.endOfChapter) {
      setSleepTimer(SleepTimerState.off);
      return;
    }
    // BUG FIX: previously, on the LAST chapter this called nextChapter()
    // which tried to load chapterIndex+1 → threw "Book has no chapters
    // or audio files" and the player died silently. Now we stop, mark
    // finished=true, and let the UI react.
    if (state.isOnLastChapter) {
      state = state.copyWith(playing: false, finished: true);
      return;
    }
    // Auto-advance to the next chapter.
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
          state = state.copyWith(sleepTimer: SleepTimerState.off);
        },
      );
    }
    // endOfChapter is handled in _onChapterEnd.
  }

  // ── Font size ──────────────────────────────────────────────────────

  Future<void> changeFontSize(double delta) async {
    final newSize = (state.readingFontSize + delta).clamp(16.0, 34.0);
    state = state.copyWith(readingFontSize: newSize);
    await ref.read(sharedPrefsProvider).setDouble('reading_font_size', newSize);
  }

  /// Called by the ReadingView's TRANSCRIBE NOW button.
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
