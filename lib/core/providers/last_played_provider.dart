import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/abs_item.dart';
import '../providers/playback_progress_provider.dart';
import '../providers/shared_prefs_provider.dart';
import '../../features/library/library_provider.dart';

/// One book + its most recent locally-saved playback position.
///
/// Computed by scanning every `playback_progress_*` entry in
/// SharedPreferences for the latest `updatedAtEpochMs`, then resolving the
/// matching [AbsItem] from the library list. Null when:
///  * the user has never played anything on this device, or
///  * the most recent book is no longer in the library (e.g. it was
///    removed on the server between sessions).
class LastPlayed {
  final AbsItem item;
  final BookPlaybackProgress progress;

  const LastPlayed({required this.item, required this.progress});

  /// Whole-book playback position in seconds — derived from the saved
  /// chapter index + within-chapter offset. Used by the Continue card to
  /// render the progress bar when `item.resumeSeconds` isn't populated.
  double get wholeBookSeconds {
    final ch = item.chapters;
    if (progress.chapterIndex < 0 || progress.chapterIndex >= ch.length) {
      return progress.positionSeconds;
    }
    return ch[progress.chapterIndex].start + progress.positionSeconds;
  }
}

/// The single "currently reading" book, or null when nothing is resumable.
final lastPlayedProvider = Provider<LastPlayed?>((ref) {
  final libraryAsync = ref.watch(libraryItemsProvider);
  final library = libraryAsync.valueOrNull;
  if (library == null) return null;

  final prefs = ref.watch(sharedPrefsProvider);

  // Find the most recently updated progress entry across every book the
  // user has ever opened on this device.
  BookPlaybackProgress? latest;
  for (final key in prefs.getKeys()) {
    if (!key.startsWith('${playbackProgressPrefsKey}_')) continue;
    final itemId = key.substring(playbackProgressPrefsKey.length + 1);
    final entry = BookPlaybackProgress.fromPrefs(prefs, itemId);
    if (entry == null) continue;
    if (latest == null ||
        (entry.updatedAtEpochMs ?? 0) > (latest.updatedAtEpochMs ?? 0)) {
      latest = entry;
    }
  }
  if (latest == null) return null;

  // Cross-reference with the library so the Continue card has a cover +
  // metadata. The book might have been removed from the server since the
  // last session — in that case, there's nothing to surface here.
  AbsItem? match;
  for (final item in library.items) {
    if (item.id == latest.itemId) {
      match = item;
      break;
    }
  }
  if (match == null) return null;

  return LastPlayed(item: match, progress: latest);
});