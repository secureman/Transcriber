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

  const AbsAudioFile({
    required this.ino,
    required this.duration,
    required this.filename,
  });

  factory AbsAudioFile.fromJson(Map<String, dynamic> json) => AbsAudioFile(
        ino: (json['ino'] as String?) ?? '',
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        filename: (json['filename'] as String?) ?? '',
      );
}

class AbsItem {
  final String id;
  final String title;
  final String author;
  final double duration; // total seconds
  final List<AbsChapter> chapters;
  final List<AbsAudioFile> audioFiles;
  final String? seriesName;
  final String? language;
  final String coverPath;
  final double progress; // 0..1 user progress from ABS

  const AbsItem({
    required this.id,
    required this.title,
    required this.author,
    required this.duration,
    required this.chapters,
    required this.audioFiles,
    this.seriesName,
    this.language,
    this.coverPath = '',
    this.progress = 0,
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

  factory AbsItem.fromJson(Map<String, dynamic> json) {
    final media = json['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final chaptersJson = media['chapters'] as List<dynamic>? ?? [];
    final filesJson = media['audioFiles'] as List<dynamic>? ?? [];
    final seriesList = metadata['seriesName'] is String
        ? null
        : metadata['series'] as List<dynamic>?;

    String? seriesName;
    if (metadata['seriesName'] is String) {
      seriesName = metadata['seriesName'] as String;
    } else if (seriesList != null && seriesList.isNotEmpty) {
      final s = seriesList.first as Map<String, dynamic>;
      seriesName = s['name'] as String?;
    }

    return AbsItem(
      id: (json['id'] as String?) ?? '',
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
