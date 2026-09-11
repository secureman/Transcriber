import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// Audio handler for background playback + lock screen controls.
/// Limits playback to a chapter's time window inside the ABS audio file
/// via [ClippingAudioSource].
class AudiobookAudioHandler extends BaseAudioHandler {
  /// Single shared player. Configured with platform-specific load
  /// controls that keep ~60 s of audio buffered ahead of the playhead
  /// (default is ~30 s) — see [_loadControl] below for the rationale.
  final AudioPlayer player = AudioPlayer(audioLoadConfiguration: _loadControl);

  static AudioLoadConfiguration get _loadControl => AudioLoadConfiguration(
        // Android: explicit min/max buffer windows. The defaults are
        // 50 s, which is already generous; v2 bumps to 120 s — on slow
        // or lossy ABS connections a bigger forward buffer is the
        // difference between a seamless chapter transition and the
        // playhead stalling mid-chapter while the data arrives.
        androidLoadControl: const AndroidLoadControl(
          minBufferDuration: Duration(seconds: 120),
          maxBufferDuration: Duration(seconds: 120),
        ),
        // iOS/macOS: ask the system to keep ~120 s of forward buffer
        // (same rationale as the Android bump above).
        darwinLoadControl: const DarwinLoadControl(
          preferredForwardBufferDuration: Duration(seconds: 120),
        ),
      );

  AudiobookAudioHandler() {
    // Report playback state changes to the system (lock screen / notif).
    player.playbackEventStream.map(_transformEvent).pipe(playbackState);
  }

  /// Loads a chapter's audio clip from the ABS server, **plus the next
  /// chapter's clip** if [nextFileIno] / [nextStartSec] / [nextEndSec] are
  /// provided. Passing them as a two-element playlist lets `just_audio`
  /// fetch and buffer the next clip in the background while the current
  /// one plays — the inter-chapter transition is gapless (auto-advance)
  /// instead of stalling on a fresh HTTP request.
  ///
  /// [startSec]/[endSec] are the chapter boundaries in seconds, either in the
  /// whole-book timeline (single-file books) or within [fileIno]'s file
  /// (multi-file books, offsets already mapped by the caller).
  ///
  /// [title]/[artist] populate the background notification + lock screen.
  ///
  /// Returns the initial playlist index (always 0 — the current chapter
  /// is at the head). The caller listens to `player.currentIndexStream`
  /// to detect the auto-advance to index 1 (chapter ended).
  Future<int> loadChapter({
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

    /// Optional next-chapter clip for prefetch. All three must be provided
    /// together; if any is null the playlist is single-item (no prefetch).
    String? nextFileIno,
    double? nextStartSec,
    double? nextEndSec,
  }) async {
    final sources = <AudioSource>[
      _urlClip(absUrl, token, itemId, fileIno, startSec, endSec),
      if (nextFileIno != null &&
          nextStartSec != null &&
          nextEndSec != null)
        _urlClip(absUrl, token, itemId, nextFileIno, nextStartSec, nextEndSec),
    ];

    // useLazyPreparation: true (default) is what enables the prefetch —
    // just_audio prepares source[0] immediately and starts preparing
    // source[1] in the background, so it's ready when index 0 ends.
    await player.setAudioSources(
      sources,
      initialIndex: 0,
      initialPosition: Duration.zero,
    );

    mediaItem.add(MediaItem(
      id: '$itemId-$fileIno-$chapterNumber',
      title: title ?? 'Audiobook',
      artist: artist,
      album: totalChapters > 0 ? 'Chapter $chapterNumber of $totalChapters' : null,
      duration: Duration(milliseconds: ((endSec - startSec) * 1000).toInt()),
    ));

    return 0;
  }

  /// Loads a chapter from a file already downloaded to device storage
  /// (offline playback). Same clipping + prefetch semantics as
  /// [loadChapter]; both source files must already be on disk.
  Future<int> loadChapterFromFile({
    required String filePath,
    required double startSec,
    required double endSec,
    String? title,
    String? artist,
    int chapterNumber = 0,
    int totalChapters = 0,

    /// Optional next-chapter clip for prefetch.
    String? nextFilePath,
    double? nextStartSec,
    double? nextEndSec,
  }) async {
    final sources = <AudioSource>[
      _fileClip(filePath, startSec, endSec),
      if (nextFilePath != null && nextStartSec != null && nextEndSec != null)
        _fileClip(nextFilePath, nextStartSec, nextEndSec),
    ];

    await player.setAudioSources(
      sources,
      initialIndex: 0,
      initialPosition: Duration.zero,
    );

    mediaItem.add(MediaItem(
      id: 'file-$chapterNumber',
      title: title ?? 'Audiobook',
      artist: artist,
      album: totalChapters > 0 ? 'Chapter $chapterNumber of $totalChapters' : null,
      duration: Duration(milliseconds: ((endSec - startSec) * 1000).toInt()),
    ));

    return 0;
  }

  ClippingAudioSource _urlClip(
    String absUrl,
    String token,
    String itemId,
    String fileIno,
    double startSec,
    double endSec,
  ) {
    final fileUrl = '$absUrl/api/items/$itemId/file/$fileIno';
    return ClippingAudioSource(
      child: AudioSource.uri(
        Uri.parse(fileUrl),
        headers: {'Authorization': 'Bearer $token'},
      ),
      start: Duration(milliseconds: (startSec * 1000).toInt()),
      end: Duration(milliseconds: (endSec * 1000).toInt()),
    );
  }

  ClippingAudioSource _fileClip(
    String filePath,
    double startSec,
    double endSec,
  ) {
    return ClippingAudioSource(
      child: AudioSource.uri(Uri.file(filePath)),
      start: Duration(milliseconds: (startSec * 1000).toInt()),
      end: Duration(milliseconds: ((endSec) * 1000).toInt()),
    );
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

  /// Forward skip uses a longer interval than the back skip (15s) — a
  /// common asymmetry in audiobook players: overshoot-and-rewind-15 is
  /// more common than needing to jump far ahead, so a bigger forward jump
  /// saves more taps on average.
  Future<void> skipForward30() async {
    final target = player.position + const Duration(seconds: 30);
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