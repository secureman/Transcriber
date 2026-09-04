import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shared_prefs_provider.dart';

class AppConfig {
  final String absUrl;
  final String absToken;
  final String backendUrl;

  const AppConfig({
    required this.absUrl,
    required this.absToken,
    required this.backendUrl,
  });

  bool get isConfigured => absUrl.isNotEmpty && absToken.isNotEmpty;

  /// The transcription backend is optional — without it, reading-view text
  /// is unavailable but playback works normally.
  bool get backendConfigured => backendUrl.isNotEmpty;

  static const _absUrlKey = 'abs_url';
  static const _absTokenKey = 'abs_token';
  static const _backendUrlKey = 'backend_url';
  static const _lastPlayedPrefix = 'last_played_chapter_';

  static AppConfig fromPrefs(SharedPreferences prefs) => AppConfig(
        absUrl: prefs.getString(_absUrlKey) ?? '',
        absToken: prefs.getString(_absTokenKey) ?? '',
        backendUrl: prefs.getString(_backendUrlKey) ?? '',
      );

  Future<void> saveToPrefs(SharedPreferences prefs) async {
    await prefs.setString(_absUrlKey, absUrl);
    await prefs.setString(_absTokenKey, absToken);
    await prefs.setString(_backendUrlKey, backendUrl);
  }

  static Future<void> clear(SharedPreferences prefs) async {
    await prefs.remove(_absUrlKey);
    await prefs.remove(_absTokenKey);
    await prefs.remove(_backendUrlKey);
  }

  static int? lastPlayedChapter(SharedPreferences prefs, String itemId) =>
      prefs.getInt('$_lastPlayedPrefix$itemId');
}

final configProvider = Provider<AppConfig>((ref) {
  // Bump configRevisionProvider after saving so this recomputes.
  ref.watch(configRevisionProvider);
  final prefs = ref.watch(sharedPrefsProvider);
  return AppConfig.fromPrefs(prefs);
});

/// Increment whenever the saved config changes to notify listeners
/// (router redirect, Dio clients) that the config was updated.
final configRevisionProvider = StateProvider<int>((ref) => 0);


/// Persists the last-played chapter index for an item.
Future<void> saveLastPlayedChapter(
  SharedPreferences prefs,
  String itemId,
  int chapterIndex,
) =>
    prefs.setInt('${AppConfig._lastPlayedPrefix}$itemId', chapterIndex);
