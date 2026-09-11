import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shared_prefs_provider.dart';

class AppConfig {
  final String absUrl;
  final String absToken;

  /// Single unified backend (accounts + progress + transcription +
  /// karaoke VTT). Formerly two separate servers (`backendUrl` +
  /// `metadataUrl`) — now one audiobook-server.
  final String serverUrl;

  const AppConfig({
    required this.absUrl,
    required this.absToken,
    this.serverUrl = '',
  });

  bool get isConfigured => absUrl.isNotEmpty && absToken.isNotEmpty;

  /// The unified server is optional — without it, accounts/progress sync
  /// and reading-view text are unavailable but playback works normally.
  bool get serverConfigured => serverUrl.isNotEmpty;

  static const _absUrlKey = 'abs_url';
  static const _absTokenKey = 'abs_token';
  static const _serverUrlKey = 'server_url';
  // Legacy keys from the two-server era. Read once for migration, then
  // removed whenever config is next saved/cleared.
  static const _legacyBackendUrlKey = 'backend_url';
  static const _legacyMetadataUrlKey = 'metadata_url';
  static const _lastPlayedPrefix = 'last_played_chapter_';

  static AppConfig fromPrefs(SharedPreferences prefs) => AppConfig(
        absUrl: prefs.getString(_absUrlKey) ?? '',
        absToken: prefs.getString(_absTokenKey) ?? '',
        serverUrl:
            prefs.getString(_serverUrlKey) ??
            // One-time migration: prefer the old progress-server URL (it
            // was required, so it's the more reliable value), falling
            // back to the transcription server.
            prefs.getString(_legacyMetadataUrlKey) ??
            prefs.getString(_legacyBackendUrlKey) ??
            '',
      );

  Future<void> saveToPrefs(SharedPreferences prefs) async {
    await prefs.setString(_absUrlKey, absUrl);
    await prefs.setString(_absTokenKey, absToken);
    await prefs.setString(_serverUrlKey, serverUrl);
    // Migration cleanup: the unified server replaces both.
    await prefs.remove(_legacyBackendUrlKey);
    await prefs.remove(_legacyMetadataUrlKey);
  }

  static Future<void> clear(SharedPreferences prefs) async {
    await prefs.remove(_absUrlKey);
    await prefs.remove(_absTokenKey);
    await prefs.remove(_serverUrlKey);
    await prefs.remove(_legacyBackendUrlKey);
    await prefs.remove(_legacyMetadataUrlKey);
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
