import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/abs_item.dart';
import 'shared_prefs_provider.dart';

/// Tracks which (item, chapter) pairs the user has finished listening to.
///
/// State is a `Set<String>` keyed by `"<itemId>/<chapterIndex>"` so a single
/// set covers all books. Persisted as a `StringList` in SharedPreferences
/// (under [kReadChaptersKey]) so the "Listened" badge survives an app
/// restart.
const kReadChaptersKey = 'read_chapters_index';

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

  /// Marks a chapter as listened. No-op if it was already marked.
  Future<void> markListened(String itemId, int chapterIndex) async {
    final k = _key(itemId, chapterIndex);
    if (state.contains(k)) return;
    final next = {...state, k};
    state = next;
    await _persist(next);
  }

  /// Un-marks a chapter as listened. No-op if it wasn't marked.
  Future<void> unmarkListened(String itemId, int chapterIndex) async {
    final k = _key(itemId, chapterIndex);
    if (!state.contains(k)) return;
    final next = {...state}..remove(k);
    state = next;
    await _persist(next);
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
  }

  Future<void> _persist(Set<String> next) => ref
      .read(sharedPrefsProvider)
      .setStringList(kReadChaptersKey, next.toList());

  /// Wipes the listened history.
  Future<void> clear() async {
    state = const <String>{};
    await ref.read(sharedPrefsProvider).remove(kReadChaptersKey);
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
