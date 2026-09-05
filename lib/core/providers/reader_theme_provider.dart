import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import 'shared_prefs_provider.dart';

/// SharedPreferences key for the chosen reader theme.
const _kReaderThemeKey = 'reader_theme';

/// Persists the user's selected reader theme across app restarts.
///
/// Exposes a synchronous [ReaderThemeType] so the UI can do
/// `ReaderThemeData.all[ref.watch(readerThemeProvider)]` directly.
class ReaderThemeController extends Notifier<ReaderThemeType> {
  @override
  ReaderThemeType build() {
    final prefs = ref.watch(sharedPrefsProvider);
    final name = prefs.getString(_kReaderThemeKey);
    if (name != null) {
      for (final t in ReaderThemeType.values) {
        if (t.name == name) return t;
      }
    }
    return ReaderThemeType.dusk; // default
  }

  /// Switches the active theme and persists the choice.
  Future<void> set(ReaderThemeType type) async {
    state = type;
    await ref
        .read(sharedPrefsProvider)
        .setString(_kReaderThemeKey, type.name);
  }
}

final readerThemeProvider =
    NotifierProvider<ReaderThemeController, ReaderThemeType>(
        ReaderThemeController.new);
