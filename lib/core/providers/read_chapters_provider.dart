import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/abs_item.dart';
import '../../features/player/player_state.dart' show bookMetaProvider;
import '../network/abs_client.dart';
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

/// In-flight mark→ABS pushes, keyed `"itemId/chapterIndex"` (and
/// `"itemId/-1"` for whole-book toggles). Prevents stacking duplicate
/// requests when the user taps quickly and gives [pendingAbsPushesProvider]
/// something to count.
final _absPushInFlight = <String>{};

/// Number of chapter-mark pushes currently being sent to Audiobookshelf.
/// Surfaces sync activity in the UI (e.g. a subtle "Syncing…" affordance)
/// without revealing whether any individual chapter is marked.
final pendingAbsPushesProvider = Provider<int>((ref) {
  ref.watch(readChaptersProvider);
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
  //                        currentTime = end of that chapter
  //  * unmarkListened    → extraData.absListenChapters -= i, isFinished=false
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
  /// the affected chapter when appropriate.
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

      await abs.patch(
        '/api/me/progress/$itemId',
        data: {
          'isFinished': false,
          if (currentTimeSec != null) 'currentTime': currentTimeSec.round(),
          'extraData': {
            ...?await _absExistingExtraData(abs, itemId),
            'absListenChapters': set.toList()..sort(),
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
  /// currentTime at the furthest marked chapter's end.
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

      await abs.patch(
        '/api/me/progress/$itemId',
        data: {
          'isFinished': false,
          'currentTime': furthest.round(),
          'extraData': {
            ...?await _absExistingExtraData(abs, itemId),
            'absListenChapters': listened.toList()..sort(),
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
