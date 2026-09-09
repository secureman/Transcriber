import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/player/player_state.dart' show bookMetaProvider;
import '../../models/abs_item.dart';
import '../network/abs_client.dart';
import '../network/abs_sync.dart';
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

/// In-flight mark→ABS pushes, keyed `"itemId/chapterIndex"` for listened
/// marks, `"itemId/chapterIndex"` (with a `pos:` prefix) for position-only
/// pushes. Prevents stacking duplicate requests when the user taps quickly
/// and gives [pendingAbsPushesProvider] something to count.
final _absPushInFlight = <String>{};

/// Number of chapter-mark pushes currently being sent to Audiobookshelf.
/// Surfaces sync activity in the UI (e.g. a subtle "Syncing…" affordance)
/// without revealing whether any individual chapter is marked.
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

  // ── ABS bridge ────────────────────────────────────────────────────────
  //
  // Audiobookshelf has no per-chapter progress storage — `MediaProgress`
  // holds only a book-level position, `isFinished`, and free-form
  // `extraData` JSON. So chapter marks are bridged to ABS as book-level
  // writes, the same way any other client would express them:
  //  * markListened      → extraData.absListenChapters += i,
  //                        currentTime = end of that chapter,
  //                        extraData.absChapterProgress[i] = chapter.end
  //  * unmarkListened    → extraData.absListenChapters -= i,
  //                        isFinished=false (position preserved)
  //  * recordChapterPosition → extraData.absChapterProgress[i] = pos
  //                            (called by the player on pause / seek)
  //  * toggleBookListened(all) → full set sync (see _pushBookMark)
  // The server's chapter times come from the cached book metadata
  // (bookMetaProvider, shared with the player UI) — no extra fetches.
  //
  // Local marks always win: the push happens in the background and never
  // blocks or reverts the UI state.

  /// ABS client, or null when offline / not configured (marks stay local).
  dynamic get _abs {
    try {
      final config = ref.read(configProvider);
      if (!config.isConfigured) return null;
      return ref.read(absClientProvider);
    } catch (_) {
      return null;
    }
  }

  /// Merges [deltaMarks] (+1 to add / −1 to remove) into the ABS media
  /// progress extraData set, moving the server's currentTime to the end of
  /// the affected chapter when appropriate. Also pins the position of the
  /// affected chapter in `absChapterProgress` so a fresh install can
  /// resume within the chapter, not just at its end.
  Future<void> _pushChapterMark(
    String itemId,
    int chapterIndex, {
    required int deltaMarks,
  }) async {
    final k = _key(itemId, chapterIndex);
    if (!_absPushInFlight.add(k)) return; // dedupe rapid taps
    _bumpPending();
    try {
      final abs = _abs;
      if (abs == null) return;
      final meta = await ref.read(bookMetaProvider(itemId).future);
      final chapters = meta?.chapters ?? const <AbsChapter>[];
      if (chapterIndex < 0 || chapterIndex >= chapters.length) return;

      final current =
          await _absProgressSet(abs, itemId, chapters.length) ?? <int>{};
      final set = {...current};
      deltaMarks > 0 ? set.add(chapterIndex) : set.remove(chapterIndex);

      // Where the mark implies the book pointer should sit: marking jumps
      // it to the end of that chapter; unmarking pulls it back to the end
      // of the furthest still-marked chapter (never claims progress past
      // everything unmarked).
      double? currentTimeSec;
      if (deltaMarks > 0) {
        currentTimeSec = chapters[chapterIndex].end;
      } else if (set.isNotEmpty) {
        currentTimeSec = set
            .where((i) => i >= 0 && i < chapters.length)
            .map((i) => chapters[i].end)
            .fold<double>(0, (a, b) => b > a ? b : a);
      }

      final extra = await _absExistingExtraData(abs, itemId) ?? const {};
      final progressJson = <String, dynamic>{
        if (extra['absChapterProgress'] is Map)
          ...Map<String, dynamic>.from(
            extra['absChapterProgress'] as Map,
          ),
      };
      // Pin the position of the affected chapter to its end on mark, or
      // leave it alone on unmark (the player may have written a partial
      // position since).
      if (deltaMarks > 0) {
        progressJson[chapterIndex.toString()] = chapters[chapterIndex].end;
      }

      await abs.patch(
        '/api/me/progress/$itemId',
        data: {
          'isFinished': false,
          if (currentTimeSec != null) 'currentTime': currentTimeSec.round(),
          'extraData': {
            ...extra,
            'absListenChapters': set.toList()..sort(),
            'absChapterProgress': progressJson,
          },
        },
      );
    } catch (_) {
      // Network/parse failure — local state already applied; ABS will be
      // reconciled by the next playback sync or a future toggle.
    } finally {
      _absPushInFlight.remove(k);
      _bumpPending();
    }
  }

  /// Applies a whole-book mark/unmark: replaces the ABS chapter set with
  /// [listened] (every index when marking, empty when unmarking) and points
  /// currentTime at the furthest marked chapter's end. Also pins each
  /// marked chapter's position to its end so a fresh install can resume
  /// at the right spot within each chapter.
  Future<void> _pushBookMark(String itemId, Set<int> listened) async {
    const k = '__book__';
    if (!_absPushInFlight.add(k)) return;
    _bumpPending();
    try {
      final abs = _abs;
      if (abs == null) return;
      final meta = await ref.read(bookMetaProvider(itemId).future);
      final chapters = meta?.chapters ?? const <AbsChapter>[];
      if (chapters.isEmpty) return;

      final furthest = listened.isEmpty
          ? 0.0
          : listened
                .where((i) => i >= 0 && i < chapters.length)
                .map((i) => chapters[i].end)
                .fold<double>(0, (a, b) => b > a ? b : a);

      final extra = await _absExistingExtraData(abs, itemId) ?? const {};
      final progressJson = <String, dynamic>{
        if (extra['absChapterProgress'] is Map)
          ...Map<String, dynamic>.from(
            extra['absChapterProgress'] as Map,
          ),
      };
      for (final i in listened) {
        if (i < 0 || i >= chapters.length) continue;
        progressJson[i.toString()] = chapters[i].end;
      }

      await abs.patch(
        '/api/me/progress/$itemId',
        data: {
          'isFinished': false,
          'currentTime': furthest.round(),
          'extraData': {
            ...extra,
            'absListenChapters': listened.toList()..sort(),
            'absChapterProgress': progressJson,
          },
        },
      );
    } catch (_) {
      // See _pushChapterMark — local-first, failures are non-fatal.
    } finally {
      _absPushInFlight.remove(k);
      _bumpPending();
    }
  }

  /// Pushes a single chapter's playback position (seconds into the
  /// chapter) to ABS, without touching the listened flag. Called by the
  /// player as the user listens — preserves "where in the chapter" so a
  /// fresh install can resume at the right offset, not just at the
  /// chapter boundary.
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
      final abs = _abs;
      if (abs == null) return;
      final meta = await ref.read(bookMetaProvider(itemId).future);
      final chapters = meta?.chapters ?? const <AbsChapter>[];
      if (chapterIndex < 0 || chapterIndex >= chapters.length) return;
      // Clamp to the chapter end so a buggy client can't push past the
      // chapter boundary and confuse the next /api/me read.
      final cap = chapters[chapterIndex].end;
      final clamped = positionSec > cap ? cap : positionSec;

      final extra = await _absExistingExtraData(abs, itemId) ?? const {};
      final progressJson = <String, dynamic>{
        if (extra['absChapterProgress'] is Map)
          ...Map<String, dynamic>.from(
            extra['absChapterProgress'] as Map,
          ),
        chapterIndex.toString(): clamped,
      };

      await abs.patch(
        '/api/me/progress/$itemId',
        data: {
          'extraData': {
            ...extra,
            'absChapterProgress': progressJson,
          },
        },
      );
    } catch (_) {
      // Silent — local state already updated; ABS will catch up on the
      // next successful sync.
    } finally {
      _absPushInFlight.remove(k);
      _bumpPending();
    }
  }

  /// Reads the currently-synced chapter set from ABS's media progress
  /// (GET /api/me/progress/:id). Returns an empty set for a fresh book
  /// (404), null when the response can't be fetched/parsed — callers then
  /// treat the in-app set as the source of truth for this write.
  Future<Set<int>?> _absProgressSet(
    dynamic abs,
    String itemId,
    int chapterCount,
  ) async {
    try {
      final res = await abs.get('/api/me/progress/$itemId');
      if (res.statusCode != 200 || res.data is! Map<String, dynamic>) {
        return res.statusCode == 404 ? <int>{} : null;
      }
      final data = res.data as Map<String, dynamic>;
      final raw =
          (data['extraData'] as Map<String, dynamic>?)?['absListenChapters'];
      if (raw is! List) return <int>{};
      return raw
          .map((e) => e is num ? e.toInt() : int.tryParse('$e'))
          .whereType<int>()
          .where((i) => i >= 0 && i < chapterCount)
          .toSet();
    } catch (_) {
      return null;
    }
  }

  /// Existing extraData map (other keys preserved on write), or null when
  /// unreadable — the patch then omits the spread and ABS keeps its copy.
  Future<Map<String, dynamic>?> _absExistingExtraData(
    dynamic abs,
    String itemId,
  ) async {
    try {
      final res = await abs.get('/api/me/progress/$itemId');
      if (res.statusCode == 200 && res.data is Map<String, dynamic>) {
        final extra = (res.data as Map<String, dynamic>)['extraData'];
        if (extra is Map<String, dynamic>) return extra;
      }
    } catch (_) {}
    return null;
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
    // Collect only this book's marked indexes for the ABS bridge.
    final bookSet = <int>{};
    for (final k in next) {
      if (!k.startsWith('$itemId/')) continue;
      final v = int.tryParse(k.substring(itemId.length + 1));
      if (v != null) bookSet.add(v);
    }
    unawaited(_pushBookMark(itemId, makeListened ? bookSet : <int>{}));
  }

  /// Records the user's current playback position within [chapterIndex]
  /// of [itemId] (seconds since the start of that chapter). Updates the
  /// local position cache immediately (so the player can show / restore
  /// it on app restart) and mirrors the value to ABS in the background
  /// so a fresh install / new device can resume at the same offset.
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

  /// Bulk-restores the per-chapter "listened" set and the per-chapter
  /// playback positions from the server's MediaProgress records (sourced
  /// from `GET /api/me`'s `mediaProgress` array — see
  /// [absMediaProgressProvider]). Listened marks come from
  /// `extraData.absListenChapters`; positions from
  /// `extraData.absChapterProgress`. Re-applying them locally brings the
  /// in-app badges AND the per-chapter resume offsets in sync with
  /// server state — no per-book detail screen visit required.
  ///
  /// Only touches books that have NO local entries yet, so it never
  /// clobbers in-session toggles or the finer-grained
  /// [restoreFromServerProgress] that fires when a book's detail screen
  /// (with real chapter boundaries) is opened.
  Future<void> restoreFromServerBulkProgress(
    Map<String, AbsMediaProgressEntry> progressByItemId,
  ) async {
    if (progressByItemId.isEmpty) return;

    final listenedAdditions = <String>{};
    final positionAdditions = <String, double>{};
    final localPositions = ref.read(chapterPositionsProvider);

    for (final entry in progressByItemId.values) {
      if (entry.libraryItemId.isEmpty) continue;

      final hasLocalListened =
          state.any((k) => k.startsWith('${entry.libraryItemId}/'));
      final hasLocalPosition = localPositions.keys
          .any((k) => k.startsWith('${entry.libraryItemId}/'));

      // Restore listened marks only if the user has no local chapter
      // state for this book yet.
      if (!hasLocalListened && entry.absListenChapters.isNotEmpty) {
        for (final i in entry.absListenChapters) {
          if (i < 0) continue;
          listenedAdditions.add(_key(entry.libraryItemId, i));
        }
      }

      // Restore positions only if the user has no local positions for
      // this book yet — same "don't clobber in-session work" guard.
      if (!hasLocalPosition && entry.chapterProgress.isNotEmpty) {
        for (final e in entry.chapterProgress.entries) {
          if (e.key < 0) continue;
          final pos = e.value;
          if (pos < 0) continue;
          positionAdditions[_key(entry.libraryItemId, e.key)] = pos;
        }
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
  }

  /// Rebuilds the listened set for [itemId] from the server's resume position,
  /// but only when this book has NO local listened entries yet (i.e. a fresh
  /// install where the local set was wiped). This is a best-effort heuristic:
  /// marks every chapter whose end falls at or before [resumeSeconds] (plus a
  /// small tolerance) as listened, so the in-app badges match the server state.
  ///
  /// Is a no-op when the local set already has entries for [itemId] (don't
  /// clobber in-session toggles or progress from another device that landed
  /// between the wipe and this call).
  Future<void> restoreFromServerProgress(
    String itemId,
    double resumeSeconds,
    List<AbsChapter> chapters,
  ) async {
    if (resumeSeconds <= 0 || chapters.isEmpty) return;
    // Bail out if the user already has local progress for this book — don't
    // overwrite in-session work or progress that landed on the server between
    // the wipe and this call.
    if (state.any((k) => k.startsWith('$itemId/'))) {
      return;
    }

    final tolerance = 15.0; // seconds — forgive small stale-ABS drift
    final threshold = resumeSeconds + tolerance;
    final toAdd = <String>{};
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      if (ch.end <= threshold) {
        toAdd.add(_key(itemId, i));
      }
    }
    if (toAdd.isEmpty) return;

    final next = {...state, ...toAdd};
    state = next;
    await _persist(next);
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

  /// Local-only write. Caller is responsible for also mirroring to ABS
  /// (see `ReadChaptersController.recordChapterPosition`).
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
