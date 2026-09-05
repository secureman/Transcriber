import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    await ref
        .read(sharedPrefsProvider)
        .setStringList(kReadChaptersKey, next.toList());
  }

  /// Wipes the listened history.
  Future<void> clear() async {
    state = const <String>{};
    await ref.read(sharedPrefsProvider).remove(kReadChaptersKey);
  }
}

final readChaptersProvider =
    NotifierProvider<ReadChaptersController, Set<String>>(
        ReadChaptersController.new);
