import 'package:sqflite/sqflite.dart';

/// Persistent metadata record for an audiobook downloaded for offline use.
///
/// [itemJson] stores the RAW ABS `/api/items/:id` payload so the app can
/// rebuild a full [AbsItem] (chapters, audio files, cover) without any
/// network access.
class OfflineBook {
  final String itemId;
  final String title;
  final String author;

  /// Raw ABS item payload (JSON) — rebuilds chapters/audio files offline.
  final String itemJson;

  /// Absolute path to the folder holding the downloaded audio files.
  final String dirPath;

  /// Absolute local path to the downloaded cover image (may be null).
  final String? coverPath;

  final int sizeBytes;
  final int downloadedAt;

  const OfflineBook({
    required this.itemId,
    required this.title,
    required this.author,
    required this.itemJson,
    required this.dirPath,
    this.coverPath,
    required this.sizeBytes,
    required this.downloadedAt,
  });

  Map<String, Object?> toRow() => {
        'item_id': itemId,
        'title': title,
        'author': author,
        'item_json': itemJson,
        'dir_path': dirPath,
        'cover_path': coverPath,
        'size_bytes': sizeBytes,
        'downloaded_at': downloadedAt,
      };

  factory OfflineBook.fromRow(Map<String, Object?> row) => OfflineBook(
        itemId: row['item_id'] as String,
        title: (row['title'] as String?) ?? 'Unknown',
        author: (row['author'] as String?) ?? '',
        itemJson: row['item_json'] as String,
        dirPath: row['dir_path'] as String,
        coverPath: row['cover_path'] as String?,
        sizeBytes: (row['size_bytes'] as int?) ?? 0,
        downloadedAt: (row['downloaded_at'] as int?) ?? 0,
      );
}

/// sqflite-backed index of downloaded books. Audio files themselves live in
/// the app documents directory — only metadata is stored in the DB.
///
/// Schema v2 adds `offline_chapters` so every downloaded audio file is
/// tracked individually:
///  * a chapter can be downloaded on its own (from the chapter list),
///  * a full-book download is resumable — files already on disk are skipped,
///  * the book counts as "fully downloaded" only when every audio file in
///    its item JSON has a row here.
class OfflineDatabase {
  OfflineDatabase._();

  static Database? _db;

  static Future<Database> _open() async {
    if (_db != null) return _db!;
    // sqflite's own databases dir (standard on Android/iOS) — avoids any
    // path_provider + SQLite path mismatch on device.
    final base = await getDatabasesPath();
    _db = await openDatabase(
      '$base/offline_books.db',
      version: 2,
      onCreate: (db, version) async {
        await db.execute(_booksTableSql);
        await db.execute(_chaptersTableSql);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 → v2: chapter-level download tracking. Idempotent.
        await db.execute(_chaptersTableSql);
      },
    );
    return _db!;
  }

  static const String _booksTableSql = '''
        CREATE TABLE IF NOT EXISTS offline_books(
          item_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          author TEXT NOT NULL,
          item_json TEXT NOT NULL,
          dir_path TEXT NOT NULL,
          cover_path TEXT,
          size_bytes INTEGER NOT NULL DEFAULT 0,
          downloaded_at INTEGER NOT NULL
        )
      ''';

  static const String _chaptersTableSql = '''
        CREATE TABLE IF NOT EXISTS offline_chapters(
          item_id TEXT NOT NULL,
          ino TEXT NOT NULL,
          file_name TEXT NOT NULL,
          bytes INTEGER NOT NULL DEFAULT 0,
          downloaded_at INTEGER NOT NULL,
          PRIMARY KEY(item_id, ino)
        )
      ''';

  static Future<void> upsert(OfflineBook book) async {
    final db = await _open();
    await db.insert(
      'offline_books',
      book.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<OfflineBook>> all() async {
    final db = await _open();
    final rows = await db.query('offline_books', orderBy: 'downloaded_at DESC');
    return rows.map(OfflineBook.fromRow).toList();
  }

  static Future<void> delete(String itemId) async {
    final db = await _open();
    await db.delete('offline_books', where: 'item_id = ?', whereArgs: [itemId]);
  }

  // ── Chapter-level tracking ────────────────────────────────────────────

  /// Records [ino] as present on disk for [itemId] (idempotent).
  static Future<void> markChapter(
    String itemId,
    String ino, {
    required String fileName,
    required int bytes,
  }) async {
    final db = await _open();
    await db.insert(
      'offline_chapters',
      {
        'item_id': itemId,
        'ino': ino,
        'file_name': fileName,
        'bytes': bytes,
        'downloaded_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// All audio-file inos currently stored on disk for [itemId].
  static Future<Set<String>> chaptersFor(String itemId) async {
    final db = await _open();
    final rows = await db.query(
      'offline_chapters',
      columns: ['ino'],
      where: 'item_id = ?',
      whereArgs: [itemId],
    );
    return {for (final r in rows) r['ino'] as String};
  }

  /// All chapter marks, grouped per book — used on startup.
  static Future<Map<String, Set<String>>> allChapters() async {
    final db = await _open();
    final rows = await db.query('offline_chapters');
    final out = <String, Set<String>>{};
    for (final r in rows) {
      out.putIfAbsent(r['item_id'] as String, () => {}).add(r['ino'] as String);
    }
    return out;
  }

  /// Drops chapter marks for [itemId] (used when the whole book is removed).
  static Future<void> removeChaptersFor(String itemId) async {
    final db = await _open();
    await db.delete('offline_chapters', where: 'item_id = ?', whereArgs: [itemId]);
  }
}