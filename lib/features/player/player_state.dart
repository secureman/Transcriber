import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/abs_client.dart';
import '../../core/offline/offline_provider.dart';
import '../../models/abs_item.dart';
import '../../models/vtt_cue.dart';
import 'audio_handler.dart';

enum VttStatus { loading, ready, notFound, transcribing, error }

enum SleepTimerState { off, min30, min60, endOfChapter }

class PlayerState {
  final String? itemId;
  final int chapterIndex;
  final int totalChapters;
  final bool audioReady;
  final bool playing;
  final bool finished; // true after the final chapter completes
  final Duration position;
  final Duration chapterDuration;
  final double speed;
  final VttStatus vttStatus;
  final List<VttCue> cues;
  final List<VttWordRef> flatWords;
  final int? currentCueIndex;
  final int? currentWordIndex;
  final SleepTimerState sleepTimer;
  final double readingFontSize;
  final bool isArabic;
  final double transcribeProgress; // 0..1 from the backend's 202 vtt response
  final bool servedFromCache;  // true when VTT was served from local cache (server offline)

  const PlayerState({
    this.itemId,
    this.chapterIndex = 0,
    this.totalChapters = 0,
    this.audioReady = false,
    this.playing = false,
    this.finished = false,
    this.position = Duration.zero,
    this.chapterDuration = Duration.zero,
    this.speed = 1.0,
    this.vttStatus = VttStatus.loading,
    this.cues = const [],
    this.flatWords = const [],
    this.currentCueIndex,
    this.currentWordIndex,
    this.sleepTimer = SleepTimerState.off,
    this.readingFontSize = 22,
    this.isArabic = false,
    this.transcribeProgress = 0,
    this.servedFromCache = false,
  });

  bool get hasVtt => vttStatus == VttStatus.ready && cues.isNotEmpty;

  /// True when there's no chapter AFTER the current one — i.e. auto-advance
  /// should NOT trigger. Returns false if totalChapters is unknown.
  bool get isOnLastChapter =>
      totalChapters > 0 && chapterIndex + 1 >= totalChapters;

  PlayerState copyWith({
    String? itemId,
    int? chapterIndex,
    int? totalChapters,
    bool? audioReady,
    bool? playing,
    bool? finished,
    Duration? position,
    Duration? chapterDuration,
    double? speed,
    VttStatus? vttStatus,
    List<VttCue>? cues,
    List<VttWordRef>? flatWords,
    int? currentCueIndex,
    int? currentWordIndex,
    bool clearWord = false,
    SleepTimerState? sleepTimer,
    double? readingFontSize,
    bool? isArabic,
    double? transcribeProgress,
    bool? servedFromCache,
  }) =>
      PlayerState(
        itemId: itemId ?? this.itemId,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        totalChapters: totalChapters ?? this.totalChapters,
        audioReady: audioReady ?? this.audioReady,
        playing: playing ?? this.playing,
        finished: finished ?? this.finished,
        position: position ?? this.position,
        chapterDuration: chapterDuration ?? this.chapterDuration,
        speed: speed ?? this.speed,
        vttStatus: vttStatus ?? this.vttStatus,
        cues: cues ?? this.cues,
        flatWords: flatWords ?? this.flatWords,
        currentCueIndex:
            clearWord ? null : (currentCueIndex ?? this.currentCueIndex),
        currentWordIndex:
            clearWord ? null : (currentWordIndex ?? this.currentWordIndex),
        sleepTimer: sleepTimer ?? this.sleepTimer,
        readingFontSize: readingFontSize ?? this.readingFontSize,
        isArabic: isArabic ?? this.isArabic,
        transcribeProgress:
            transcribeProgress ?? this.transcribeProgress,
        servedFromCache: servedFromCache ?? this.servedFromCache,
      );
}

/// Lazily creates and caches the global audio handler.
final audioHandlerProvider = Provider<AudiobookAudioHandler>((ref) {
  final handler = AudiobookAudioHandler();
  ref.onDispose(() => handler.stop());
  return handler;
});

/// Small cached provider for player header info (title/author/cover).
/// Serves downloaded books instantly from local storage; otherwise fetches
/// from ABS, returning null when the server is unreachable.
final bookMetaProvider = FutureProvider.family<AbsItem?, String>(
  (ref, itemId) async {
    final offlineBook = ref.watch(offlineStoreProvider).books[itemId];
    if (offlineBook != null) {
      return AbsItem.fromJson(
        jsonDecode(offlineBook.itemJson) as Map<String, dynamic>,
      );
    }
    final abs = ref.read(absClientProvider);
    try {
      final res = await abs.get('/api/items/$itemId');
      if (res.statusCode != 200) return null;
      return AbsItem.fromJson(res.data as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  },
);
