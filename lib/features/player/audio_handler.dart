import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// Audio handler for background playback + lock screen controls.
/// Limits playback to a chapter's time window inside the ABS audio file
/// via [ClippingAudioSource].
class AudiobookAudioHandler extends BaseAudioHandler {
  final AudioPlayer player = AudioPlayer();

  AudiobookAudioHandler() {
    // Report playback state changes to the system (lock screen / notif).
    player.playbackEventStream.map(_transformEvent).pipe(playbackState);
  }

  /// Loads a chapter's audio clip from the ABS server.
  ///
  /// [startSec]/[endSec] are the chapter boundaries in seconds, either in the
  /// whole-book timeline (single-file books) or within [fileIno]'s file
  /// (multi-file books, offsets already mapped by the caller).
  ///
  /// [title]/[artist] populate the background notification + lock screen.
  Future<void> loadChapter({
    required String absUrl,
    required String token,
    required String itemId,
    required String fileIno,
    required double startSec,
    required double endSec,
    String? title,
    String? artist,
    int chapterNumber = 0,
    int totalChapters = 0,
  }) async {
    final fileUrl = '$absUrl/api/items/$itemId/file/$fileIno';
    final source = ClippingAudioSource(
      child: AudioSource.uri(
        Uri.parse(fileUrl),
        headers: {'Authorization': 'Bearer $token'},
      ),
      start: Duration(milliseconds: (startSec * 1000).toInt()),
      end: Duration(milliseconds: (endSec * 1000).toInt()),
    );
    await player.setAudioSource(source);

    // Update the lock-screen / notification metadata.
    mediaItem.add(MediaItem(
      id: '$itemId-$fileIno-$chapterNumber',
      title: title ?? 'Audiobook',
      artist: artist,
      album: totalChapters > 0 ? 'Chapter $chapterNumber of $totalChapters' : null,
      duration: Duration(milliseconds: ((endSec - startSec) * 1000).toInt()),
    ));
  }

  /// Loads a chapter from a file already downloaded to device storage
  /// (offline playback). Same clipping semantics as [loadChapter].
  Future<void> loadChapterFromFile({
    required String filePath,
    required double startSec,
    required double endSec,
    String? title,
    String? artist,
    int chapterNumber = 0,
    int totalChapters = 0,
  }) async {
    final source = ClippingAudioSource(
      child: AudioSource.uri(Uri.file(filePath)),
      start: Duration(milliseconds: (startSec * 1000).toInt()),
      end: Duration(milliseconds: (endSec * 1000).toInt()),
    );
    await player.setAudioSource(source);

    mediaItem.add(MediaItem(
      id: 'file-$chapterNumber',
      title: title ?? 'Audiobook',
      artist: artist,
      album: totalChapters > 0 ? 'Chapter $chapterNumber of $totalChapters' : null,
      duration: Duration(milliseconds: ((endSec - startSec) * 1000).toInt()),
    ));
  }

  /// Finds which audio file contains [seconds] (book timeline) and returns
  /// its ino plus the offset within that file. Works for both single-file
  /// (everything maps to file 0) and multi-file books.
  static (String ino, double offsetInFile) resolveFilePosition({
    required List<({String ino, double duration})> files,
    required double seconds,
  }) {
    var cursor = 0.0;
    for (final f in files) {
      if (seconds < cursor + f.duration || identical(f, files.last)) {
        return (f.ino, seconds - cursor);
      }
      cursor += f.duration;
    }
    if (files.isEmpty) return ('', seconds);
    return (files.last.ino, seconds);
  }

  @override
  Future<void> play() async {
    await player.play();
  }

  @override
  Future<void> pause() async {
    await player.pause();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> setSpeed(double speed) => player.setSpeed(speed);

  Future<void> skipForward15() async {
    final target = player.position + const Duration(seconds: 15);
    final end = player.duration;
    await player.seek(end != null && target > end ? end : target);
  }

  Future<void> skipBackward15() async {
    final target = player.position - const Duration(seconds: 15);
    await player.seek(target < Duration.zero ? Duration.zero : target);
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      processingState: switch (player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: player.playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: event.currentIndex,
    );
  }
}
