import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/abs_item.dart';
import '../../models/metadata_progress.dart';
import '../../features/player/player_state.dart' show bookMetaProvider;
import '../network/metadata_client.dart';
import '../network/progress_sync.dart';
import 'config_provider.dart';
import 'playback_progress_provider.dart';
import 'shared_prefs_provider.dart';

/// Tracks which (item, chapter) pairs the user has finished listening to.
///
/// State is a `Set<String>` keyed by `"<itemId>/<chapterIndex>"` so a single
/// set covers all books. Persisted as a `StringList` in SharedPreferences
/// (under [kReadChaptersKey]) so the "Listened" badge survives an app
/// restart.
const kReadChaptersKey = 'read_chapters_index';

/// In-flight mark→progress-server pushes, keyed `"itemId/chapterIndex"` for
/// listened marks, `"itemId/chapterIndex"` (with a `pos:` prefix) for
/// position-only pushes. Prevents stacking duplicate requests when the
/// user taps quickly and gives [pendingAbsPushesProvider] something
/// to count.
final _absPushInFlight = <String>{};

/// Number of chapter-mark pushes currently being sent to the progress
/// server. Surfaces sync activity in the UI (e.g. a subtle "Syncing…"
/// affordance) without revealing whether any individual chapter is marked.
final pendingAbsPushesProvider = Provider<int>((ref) {
  ref.watch(readChaptersProvider);
  ref.watch(chapterPositionsProvider);
  return _absPushInFlight.length;
});

class ReadChaptersController extends Notifier<Set<String>> {
  static String _key(String itemId, int chapterIndex) =>
      '$itemId/$chapterIndex';

  @override
  Set<String> build() {
    final prefs = ref.watch(sharedPrefsProvider);
    final stored = prefs.getStringList(kReadChaptersKey) ?? const <String>[];
    return stored.toSet();
  }

  bool isListened(String itemId, int chapterIndex) =>
      state.contains(_key(itemId, chapterIndex));

  // ── Metadata-server bridge ────────────────────────────────────────────
  //
  // Reading progress lives on the metadata server, which stocks native
  // per-chapter rows — no read-modify-write, no extraData JSON:
  //  * markListened      → POST   /api/progress/chapter/{item}/{i}/done
  //  * unmarkListened    → DELETE /api/progress/chapter/{item}/{i}/done
  //  * recordChapterPosition → PUT /api/progress/chapter/{item}/{i}/position
  //  * toggleBookListened(all) → PUT /api/progress/book/{item}/chapters
  // The server's chapter times come from the cached book metadata
  // (bookMetaProvider, shared with the player UI) — no extra fetches.
  //
  // Local marks always win: the push happens in the background and never
  // blocks or reverts the UI state.

  /// Progress syncer, or null when offline / not configured / no API token
  /// (marks then stay local-only until the next startup bulk restore).
  dynamic get _syncer {
    try {
      final config = ref.read(configProvider);
      final token = config.absToken;
      if (!config.serverConfigured || token.isEmpty) return null;
      return ref.read(progressSyncProvider);
    } catch (_) {
      return null;
    }
  }

  /// Pushes a mark/unmark to the metadata server. Idempotent — the server
  /// stores per-chapter done rows directly, so there's no read-modify-write
  /// and no chapter-boundary math needed server-side.
  Future<void> _pushChapterMark(
    String itemId,
    int chapterIndex, {
    required int deltaMarks,
  }) async {
    final k = _key(itemId, chapterIndex);
    if (!_absPushInFlight.add(k)) return; // dedupe rapid taps
    _bumpPending();
    try {
      final syncer = _syncer;
      if (syncer == null) return;
      if (deltaMarks > 0) {
        await syncer.chapterDone(itemId, chapterIndex);
      } else {
        await syncer.chapterNotDone(itemId, chapterIndex);
      }
    } catch (_) {
      // Network/parse failure — local state already applied; the server is
      // reconciled by the next playback sync or a future toggle.
    } finally {
      _absPushInFlight.remove(k);
      _bumpPending();
    }
  }


  /// Applies a whole-book mark/unmark: replaces the metadata server's
  /// chapter-done set with [listened] (every index when marking, empty when
  /// unmarking) in a single round trip.
  Future<void> _pushBookMark(String itemId, Set<int> listened) async {
    final k = 'book:$itemId';
    if (!_absPushInFlight.add(k)) return;
    _bumpPending();
    try {
      final syncer = _syncer;
      if (syncer == null) return;
      await syncer.replaceBookChapters(itemId, listened);
    } catch (_) {
      // See _pushChapterMark — local-first, failures are non-fatal.
    } finally {
      _absPushInFlight.remove(k);
      _bumpPending();
    }
  }


  /// Pushes a single chapter's playback position (seconds into the chapter)
  /// to the metadata server, without touching the listened flag. Called by
  /// the player as the user listens — preserves "where in the chapter" so a
  /// fresh install can resume at the right offset, not just at the chapter
  /// boundary.
  Future<void> _pushChapterPosition(
    String itemId,
    int chapterIndex,
    double positionSec,
  ) async {
    if (positionSec <= 0) return;
    final k = 'pos:${_key(itemId, chapterIndex)}';
    if (!_absPushInFlight.add(k)) return; // dedupe rapid position updates
    _bumpPending();
    try {
      final syncer = _syncer;
      if (syncer == null) return;
      final meta = await ref.read(bookMetaProvider(itemId).future);
      final chapters = meta?.chapters ?? const <AbsChapter>[];
      if (chapterIndex < 0 || chapterIndex >= chapters.length) return;
      // Clamp to the chapter end so the server never stores a position past
      // the chapter boundary.
      final cap = chapters[chapterIndex].end;
      final clamped = positionSec > cap ? cap : positionSec;
      await syncer.chapterPosition(itemId, chapterIndex, clamped);
    } catch (_) {
      // Silent — local state already updated; the server catches up on the
      // next successful sync.
    } finally {
      _absPushInFlight.remove(k);
      _bumpPending();
    }
  }

  void _bumpPending() {
    // Re-evaluate the pending-count provider (it watches this notifier).
    state = state;
  }

  /// Marks a chapter as listened. No-op if it was already marked.
  Future<void> markListened(String itemId, int chapterIndex) async {
    final k = _key(itemId, chapterIndex);
    if (state.contains(k)) return;
    final next = {...state, k};
    state = next;
    await _persist(next);
    unawaited(_pushChapterMark(itemId, chapterIndex, deltaMarks: 1));
  }

  /// Un-marks a chapter as listened. No-op if it wasn't marked.
  Future<void> unmarkListened(String itemId, int chapterIndex) async {
    final k = _key(itemId, chapterIndex);
    if (!state.contains(k)) return;
    final next = {...state}..remove(k);
    state = next;
    await _persist(next);
    unawaited(_pushChapterMark(itemId, chapterIndex, deltaMarks: -1));
  }

  /// Flips a single chapter's listened flag. Used by long-press.
  Future<void> toggleListened(String itemId, int chapterIndex) =>
      isListened(itemId, chapterIndex)
      ? unmarkListened(itemId, chapterIndex)
      : markListened(itemId, chapterIndex);

  /// True only when every chapter 0..chapterCount-1 of [itemId] is marked.
  bool isBookListened(String itemId, int chapterCount) {
    if (chapterCount <= 0) return false;
    for (var i = 0; i < chapterCount; i++) {
      if (!state.contains(_key(itemId, i))) return false;
    }
    return true;
  }

  /// Marks every chapter of the book as listened (long-press on the book
  /// cover). If it's already fully listened, un-marks all of them instead —
  /// same toggle affordance as a single chapter.
  Future<void> toggleBookListened(String itemId, int chapterCount) async {
    if (chapterCount <= 0) return;
    final makeListened = !isBookListened(itemId, chapterCount);
    final next = {...state};
    for (var i = 0; i < chapterCount; i++) {
      final k = _key(itemId, i);
      if (makeListened) {
        next.add(k);
      } else {
        next.remove(k);
      }
    }
    state = next;
    await _persist(next);
    // Collect only this book's marked indexes for the metadata-server
    // bridge. Bound against chapterCount so any out-of-range index that
    // slipped in via a bulk server restore doesn't round-trip back to
    // the server.
    final bookSet = <int>{};
    for (final k in next) {
      if (!k.startsWith('$itemId/')) continue;
      final v = int.tryParse(k.substring(itemId.length + 1));
      if (v != null && v >= 0 && v < chapterCount) bookSet.add(v);
    }
    unawaited(_pushBookMark(itemId, makeListened ? bookSet : <int>{}));
  }

  /// Records the user's current playback position within [chapterIndex]
  /// of [itemId] (seconds since the start of that chapter). Updates the
  /// local position cache immediately (so the player can show / restore
  /// it on app restart) and mirrors the value to the metadata server in
  /// the background so a fresh install / new device resumes at the same
  /// offset.
  Future<void> recordChapterPosition(
    String itemId,
    int chapterIndex,
    double positionSec,
  ) async {
    if (positionSec <= 0) return;
    await ref
        .read(chapterPositionsProvider.notifier)
        .recordLocal(itemId, chapterIndex, positionSec);
    unawaited(_pushChapterPosition(itemId, chapterIndex, positionSec));
  }

  Future<void> _persist(Set<String> next) => ref
      .read(sharedPrefsProvider)
      .setStringList(kReadChaptersKey, next.toList());

  /// Wipes the listened history.
  Future<void> clear() async {
    state = const <String>{};
    await ref.read(sharedPrefsProvider).remove(kReadChaptersKey);
  }

  // ── Last-position reads (for the player's chapter strip) ─────────────

  /// Where the user last stopped in [itemId]: chapter index + seconds into
  /// that chapter, from the local playback-progress store. Null when the
  /// book was never opened on this device. Also re-exposes the same record
  /// as a [BookPlaybackProgress] for callers that want the timestamp.
  BookPlaybackProgress? savedProgress(String itemId) =>
      BookPlaybackProgress.fromPrefs(ref.read(sharedPrefsProvider), itemId);

  ({int chapterIndex, double positionSeconds})? lastPosition(String itemId) {
    final p = savedProgress(itemId);
    if (p == null) return null;
    return (chapterIndex: p.chapterIndex, positionSeconds: p.positionSeconds);
  }

  /// Bulk-restores the per-chapter "listened" set, the per-chapter playback
  /// positions, AND each book's continue-reading bookmark from the metadata
  /// server's bulk progress payload (see `GET /api/progress`). Re-applying
  /// them locally brings the in-app badges, per-chapter resume offsets,
  /// AND the continue card in sync with server state — no per-book detail
  /// screen visit required.
  ///
  /// Only touches books that have NO local entries yet, so it never
  /// clobbers in-session toggles or the finer-grained
  /// [restoreFromServerProgress] that fires when a book's detail screen
  /// (with real chapter boundaries) is opened.
  Future<void> restoreFromMetadataBulk(
    MetadataBulkProgress progress,
  ) async {
    if (progress.bookProgress.isEmpty &&
        progress.chaptersDone.isEmpty &&
        progress.chapterPositions.isEmpty) {
      return;
    }

    final listenedAdditions = <String>{};
    final positionAdditions = <String, double>{};
    final localPositions = ref.read(chapterPositionsProvider);

    for (final itemId in progress.chaptersDone.keys) {
      if (itemId.isEmpty) continue;
      final hasLocalListened = state.any((k) => k.startsWith('$itemId/'));
      // Restore listened marks only if the user has no local chapter
      // state for this book yet.
      if (!hasLocalListened) {
        for (final i in progress.chaptersDone[itemId] ?? const <int>[]) {
          if (i < 0) continue;
          listenedAdditions.add(_key(itemId, i));
        }
      }
    }

    for (final itemId in progress.chapterPositions.keys) {
      if (itemId.isEmpty) continue;
      final hasLocalPosition =
          localPositions.keys.any((k) => k.startsWith('$itemId/'));
      // Restore positions only if the user has no local positions for
      // this book yet — same "don't clobber in-session work" guard.
      if (!hasLocalPosition) {
        final positions = progress.chapterPositions[itemId] ?? const {};
        positions.forEach((i, pos) {
          if (i < 0 || pos < 0) return;
          positionAdditions[_key(itemId, i)] = pos;
        });
      }
    }

    if (listenedAdditions.isNotEmpty) {
      final next = {...state, ...listenedAdditions};
      state = next;
      await _persist(next);
    }
    if (positionAdditions.isNotEmpty) {
      await ref
          .read(chapterPositionsProvider.notifier)
          .mergeFromServer(positionAdditions);
    }

    // Continue-reading bookmarks — only for books with no local bookmark
    // yet, so in-session playback always wins.
    final prefs = ref.read(sharedPrefsProvider);
    for (final book in progress.bookProgress.values) {
      final idx = book.lastChapterIndex;
      final pos = book.lastPositionSeconds;
      if (idx == null || pos == null) continue;
      if (BookPlaybackProgress.fromPrefs(prefs, book.absItemId) != null) {
        continue;
      }
      await BookPlaybackProgress.save(prefs, book.absItemId, idx, pos);
    }
  }

  /// Rebuilds the listened set AND per-chapter playback positions for
  /// [itemId] from the metadata server, but only when this book has NO
  /// local entries yet (i.e. a fresh install where the local stores were
  /// wiped). Best-effort, two parts:
  ///
  ///  * Listened marks: taken from the server's chapter_done set
  ///    (`GET /api/progress`, per-book slice) — every row the server has
  ///    is marked, matching the server state exactly.
  ///  * Per-chapter positions: merged from the server's per-chapter
  ///    position rows for this book.
  ///
  /// Each restore is independently guarded by its own "no local entries
  /// for this book yet" check, so the two don't clobber each other or
  /// in-session work.
  Future<void> restoreFromServerProgress(
    String itemId,
    List<AbsChapter> chapters,
  ) async {
    if (chapters.isEmpty) return;

    MetadataBulkProgress? progress;
    try {
      progress = await ref.read(metadataProgressProvider.future);
    } catch (_) {
      return;
    }
    if (progress == null) return;

    // 1. Listened-marks — only when no local listened entries exist for
    // this book yet.
    final hasLocalListened = state.any((k) => k.startsWith('$itemId/'));
    if (!hasLocalListened) {
      final toAdd = <String>{};
      for (final i in progress.chaptersDone[itemId] ?? const <int>[]) {
        if (i < 0 || i >= chapters.length) continue;
        toAdd.add(_key(itemId, i));
      }
      if (toAdd.isNotEmpty) {
        final next = {...state, ...toAdd};
        state = next;
        await _persist(next);
      }
    }

    // 2. Per-chapter positions — only when no local positions exist for
    // this book yet.
    final localPositions = ref.read(chapterPositionsProvider);
    if (localPositions.keys.any((k) => k.startsWith('$itemId/'))) return;
    final positions = progress.chapterPositions[itemId] ?? const {};
    if (positions.isEmpty) return;
    final positionAdditions = <String, double>{};
    positions.forEach((i, d) {
      if (i < 0 || i >= chapters.length || d < 0) return;
      // Clamp to the chapter's local bounds so a stale value (chapter
      // times changed on the server) can't push the player past the
      // chapter start or end.
      final ch = chapters[i];
      final clamped = d.clamp(0.0, ch.end - ch.start);
      positionAdditions[_key(itemId, i)] = clamped;
    });
    if (positionAdditions.isNotEmpty) {
      await ref
          .read(chapterPositionsProvider.notifier)
          .mergeFromServer(positionAdditions);
    }
  }
}

final readChaptersProvider =
    NotifierProvider<ReadChaptersController, Set<String>>(
      ReadChaptersController.new,
    );

// ── Per-chapter playback positions ────────────────────────────────────
//
// Separate from the listened-marks set above: positions are dense
// (every chapter the player touched, not just completed ones) and live
// alongside — not inside — the listened flag. The state is a Map keyed
// by `"<itemId>/<chapterIndex>"` mapping to seconds-since-chapter-start.

const _kChapterPositionsKey = 'chapter_positions';

class ChapterPositionsController extends Notifier<Map<String, double>> {
  static String _key(String itemId, int chapterIndex) =>
      '$itemId/$chapterIndex';

  @override
  Map<String, double> build() {
    final prefs = ref.watch(sharedPrefsProvider);
    final stored = prefs.getStringList(_kChapterPositionsKey) ?? const [];
    final out = <String, double>{};
    for (final s in stored) {
      // Serialized as "itemId/chapterIndex|position" so the slash inside
      // the key never collides with the pipe separator.
      final sep = s.lastIndexOf('|');
      if (sep <= 0) continue;
      final k = s.substring(0, sep);
      final v = double.tryParse(s.substring(sep + 1));
      if (v == null || v < 0) continue;
      out[k] = v;
    }
    return out;
  }

  /// Returns the saved position for [chapterIndex] of [itemId], or null
  /// when the user has never played (or never saved a position in) that
  /// chapter on this device.
  double? get(String itemId, int chapterIndex) =>
      state[_key(itemId, chapterIndex)];

  /// Local-only write. Caller is responsible for also mirroring to the
  /// metadata server (see `ReadChaptersController.recordChapterPosition`).
  Future<void> recordLocal(
    String itemId,
    int chapterIndex,
    double positionSec,
  ) async {
    if (positionSec <= 0) return;
    final k = _key(itemId, chapterIndex);
    final current = state[k];
    if (current != null && (current - positionSec).abs() < 0.5) return;
    final next = {...state, k: positionSec};
    state = next;
    await _persist(next);
  }

  /// Bulk merge from server-restore — only writes keys that don't exist
  /// locally yet, so an in-session position (e.g. the user has been
  /// listening for 10 minutes since the restore ran) is never clobbered.
  Future<void> mergeFromServer(Map<String, double> additions) async {
    if (additions.isEmpty) return;
    final next = {...state};
    var changed = false;
    for (final e in additions.entries) {
      if (next.containsKey(e.key)) continue;
      next[e.key] = e.value;
      changed = true;
    }
    if (!changed) return;
    state = next;
    await _persist(next);
  }

  Future<void> _persist(Map<String, double> next) => ref
      .read(sharedPrefsProvider)
      .setStringList(
        _kChapterPositionsKey,
        next.entries.map((e) => '${e.key}|${e.value}').toList(),
      );
}

final chapterPositionsProvider =
    NotifierProvider<ChapterPositionsController, Map<String, double>>(
      ChapterPositionsController.new,
    );
