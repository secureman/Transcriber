class AbsChapter {
  final int id;
  final double start;
  final double end;
  final String title;

  const AbsChapter({
    required this.id,
    required this.start,
    required this.end,
    required this.title,
  });

  double get duration => end - start;

  factory AbsChapter.fromJson(Map<String, dynamic> json) => AbsChapter(
        id: (json['id'] as num?)?.toInt() ?? 0,
        start: (json['start'] as num?)?.toDouble() ?? 0,
        end: (json['end'] as num?)?.toDouble() ?? 0,
        title: (json['title'] as String?) ?? 'Chapter',
      );
}

class AbsAudioFile {
  final String ino;
  final double duration;
  final String filename;

  /// Lowercase file extension WITHOUT the leading dot (e.g. "mp3", "m4b").
  /// Falls back to "mp3" when unknown.
  final String ext;

  const AbsAudioFile({
    required this.ino,
    required this.duration,
    required this.filename,
    this.ext = 'mp3',
  });

  factory AbsAudioFile.fromJson(Map<String, dynamic> json) {
    // In ABS item JSON, the display filename + ext live nested under
    // `metadata`, not at the top level:
    //   "ino": "1329732",
    //   "metadata": { "filename": "...", "ext": ".mp3", ... }
    final metadata = json['metadata'] as Map<String, dynamic>? ?? const {};
    final rawExt = metadata['ext'] as String? ?? '';
    // `ino` may come back as a number or a string depending on ABS version.
    final rawIno = json['ino'];
    return AbsAudioFile(
      ino: rawIno == null ? '' : rawIno.toString(),
      duration: (json['duration'] as num?)?.toDouble() ?? 0,
      filename: (metadata['filename'] as String?) ?? '',
      ext: rawExt.startsWith('.')
          ? rawExt.substring(1).toLowerCase()
          : rawExt.toLowerCase(),
    );
  }

  /// The filename used when this audio file is saved to disk for offline use.
  /// Kept identical between the downloader and the offline player so the
  /// saved file is always found on playback.
  String get offlineFilename =>
      'audio_$ino.${ext.isEmpty ? 'mp3' : ext}';
}

class AbsItem {
  final String id;
  final String mediaId; // e.g. "li_..." — used for ABS progress sync
  final String title;
  final String author;
  final double duration; // total seconds
  final List<AbsChapter> chapters;
  final List<AbsAudioFile> audioFiles;
  final String? seriesName;
  final String? language;
  final String coverPath;
  final double progress; // 0..1 user progress from ABS
  /// Exact whole-book-timeline resume position in seconds, from ABS's
  /// `userMediaProgress.currentTime` (only present when the item was
  /// fetched with `?expanded=1`). Null when ABS reports no progress yet.
  final double? resumeSeconds;
  final String? narratorName;

  const AbsItem({
    required this.id,
    required this.title,
    required this.author,
    required this.duration,
    required this.chapters,
    required this.audioFiles,
    this.mediaId = '',
    this.seriesName,
    this.language,
    this.coverPath = '',
    this.progress = 0,
    this.resumeSeconds,
    this.narratorName,
  });

  bool get isArabic =>
      language != null &&
      (language!.toLowerCase() == 'ar' || language!.toLowerCase().startsWith('ar-'));

  /// URL for the cover image. Uses ABS's dedicated cover endpoint which
  /// accepts the Bearer token header (works for both minified library
  /// items and full item JSON). If [coverPath] is already an absolute
  /// URL (e.g. from the backend's metadata proxy), return it as-is.
  String coverUrl(String absUrl) {
    if (coverPath.startsWith('http')) return coverPath;
    return '$absUrl/api/items/$id/cover';
  }

  /// The audio file (by ino) that contains the start of [chapterIndex].
  /// Mirrors AudiobookAudioHandler.resolveFilePosition. Returns '' when the
  /// mapping can't be made (no chapters/files or index out of range).
  String fileInoForChapter(int chapterIndex) {
    if (chapters.isEmpty || audioFiles.isEmpty) return '';
    if (chapterIndex < 0 || chapterIndex >= chapters.length) return '';
    final start = chapters[chapterIndex].start;
    var cursor = 0.0;
    for (final f in audioFiles) {
      if (start < cursor + f.duration || identical(f, audioFiles.last)) {
        return f.ino;
      }
      cursor += f.duration;
    }
    return audioFiles.last.ino;
  }

  /// Maps [resumeSeconds] onto a specific chapter, for callers that want
  /// to know "which chapter (and how far into it) should we resume into"
  /// without duplicating the chapter-range scan themselves. Returns null
  /// when there's no progress yet, or it's past the end of the book.
  ({int chapterIndex, double offsetSeconds})? resumePosition() {
    final target = resumeSeconds;
    if (target == null || target <= 0 || chapters.isEmpty) return null;
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      if (target >= ch.start && target < ch.end) {
        return (chapterIndex: i, offsetSeconds: target - ch.start);
      }
    }
    return null;
  }

  /// Copies this item with a freshly-fetched resume position. Used when the
  /// primary metadata source (the transcription backend's BookMeta proxy)
  /// has no progress field of its own — see bookDetailProvider.
  AbsItem copyWithResume(double? resumeSeconds) => AbsItem(
        id: id,
        mediaId: mediaId,
        title: title,
        author: author,
        duration: duration,
        chapters: chapters,
        audioFiles: audioFiles,
        seriesName: seriesName,
        language: language,
        coverPath: coverPath,
        progress: progress,
        resumeSeconds: resumeSeconds,
        narratorName: narratorName,
      );

  factory AbsItem.fromJson(Map<String, dynamic> json) {
    final media = json['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final chaptersJson = media['chapters'] as List<dynamic>? ?? [];
    final filesJson = media['audioFiles'] as List<dynamic>? ?? [];
    final seriesList = metadata['seriesName'] is String
        ? null
        : metadata['series'] as List<dynamic>?;
    // Only present when fetched with ?expanded=1 — see LibraryItemController
    // findOne() in the ABS server source, which gates this behind that
    // query param via req.user.getOldMediaProgress(...).
    final mediaProgress = json['userMediaProgress'] as Map<String, dynamic>?;
    final narrators = metadata['narrators'] as List<dynamic>?;

    String? seriesName;
    if (metadata['seriesName'] is String) {
      seriesName = metadata['seriesName'] as String;
    } else if (seriesList != null && seriesList.isNotEmpty) {
      final s = seriesList.first as Map<String, dynamic>;
      seriesName = s['name'] as String?;
    }

    return AbsItem(
      id: (json['id'] as String?) ?? '',
      mediaId: (media['id'] as String?) ?? '',
      title: (metadata['title'] as String?) ?? (json['name'] as String?) ?? 'Unknown',
      author: (metadata['authorName'] as String?) ?? '',
      duration: (media['duration'] as num?)?.toDouble() ?? 0,
      chapters: chaptersJson
          .map((c) => AbsChapter.fromJson(c as Map<String, dynamic>))
          .toList(),
      audioFiles: filesJson
          .map((f) => AbsAudioFile.fromJson(f as Map<String, dynamic>))
          .toList(),
      seriesName: seriesName,
      language: metadata['language'] as String?,
      coverPath:
          (media['coverPath'] as String?) ?? (json['coverPath'] as String?) ?? '',
      progress:
          (media['progress'] as num?)?.toDouble() ?? (json['progress'] as num?)?.toDouble() ?? 0,
      resumeSeconds: (mediaProgress?['currentTime'] as num?)?.toDouble(),
      narratorName: (narrators != null && narrators.isNotEmpty)
          ? narrators.first as String?
          : null,
    );
  }

  /// Parses lightweight book metadata returned by the transcription
  /// backend's GET /api/metadata/{item_id} (BookMeta schema).
  factory AbsItem.fromBackendMeta(Map<String, dynamic> json) {
    final chaptersJson = json['chapters'] as List<dynamic>? ?? [];
    return AbsItem(
      id: (json['item_id'] as String?) ?? '',
      title: (json['title'] as String?) ?? 'Unknown',
      author: (json['author'] as String?) ?? '',
      duration: (json['duration'] as num?)?.toDouble() ?? 0,
      chapters: chaptersJson
          .map((c) {
            final m = c as Map<String, dynamic>;
            return AbsChapter(
              id: (m['index'] as num?)?.toInt() ?? 0,
              start: (m['start'] as num?)?.toDouble() ?? 0,
              end: (m['end'] as num?)?.toDouble() ?? 0,
              title: (m['title'] as String?) ?? 'Chapter',
            );
          })
          .toList(),
      audioFiles: const [],
      coverPath: (json['cover_url'] as String?) ?? '',
    );
  }

  /// Parses a lightweight item from library list responses
  /// (media.metadata is nested directly under the item in this case).
  factory AbsItem.fromLibraryJson(Map<String, dynamic> json) {
    final item = AbsItem.fromJson(json);
    return item;
  }
}
