import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/abs_client.dart';
import '../../models/abs_item.dart';
import '../../models/vtt_cue.dart';
import 'audio_handler.dart';

enum VttStatus { loading, ready, notFound, transcribing, error }

enum SleepTimerState { off, min30, min60, endOfChapter }

class PlayerState {
  final String? itemId;
  final int chapterIndex;
  final bool audioReady;
  final bool playing;
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

  const PlayerState({
    this.itemId,
    this.chapterIndex = 0,
    this.audioReady = false,
    this.playing = false,
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
  });

  bool get hasVtt => vttStatus == VttStatus.ready && cues.isNotEmpty;

  PlayerState copyWith({
    String? itemId,
    int? chapterIndex,
    bool? audioReady,
    bool? playing,
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
  }) =>
      PlayerState(
        itemId: itemId ?? this.itemId,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        audioReady: audioReady ?? this.audioReady,
        playing: playing ?? this.playing,
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
      );
}

/// Lazily creates and caches the global audio handler.
final audioHandlerProvider = Provider<AudiobookAudioHandler>((ref) {
  final handler = AudiobookAudioHandler();
  ref.onDispose(() => handler.stop());
  return handler;
});

/// Small cached provider for player header info (title/author/cover),
/// fetched directly from ABS.
final bookMetaProvider = FutureProvider.family<AbsItem?, String>(
  (ref, itemId) async {
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
