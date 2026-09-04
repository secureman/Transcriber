import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Wraps the platform channel that talks to MainActivity.kt to ask
/// Android to ignore battery optimizations for our app. Required on
/// aggressive OEMs (Xiaomi, Samsung, Huawei, etc.) to keep the
/// foreground mediaPlayback service alive when the app is backgrounded.
class BatteryOptimization {
  static const _channel = MethodChannel('ereader/battery_optimization');
  // Persistence keys — never re-prompt the user after they've already
  // been asked (or denied). One shot per install.
  static const _askedKey = 'battery_opt_asked_v1';
  static const _resultKey = 'battery_opt_result_v1';

  /// True on platforms that don't have a battery optimization concept
  /// (iOS, desktop) or when the channel isn't wired up (tests).
  static Future<bool> isIgnoring() async {
    try {
      final r = await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      return r ?? true;
    } on PlatformException {
      return true; // assume OK on non-Android
    } on MissingPluginException {
      return true;
    }
  }

  /// Open the system dialog. Returns true if the dialog was shown
  /// (or the fallback settings page), false if nothing happened.
  static Future<bool> requestIgnore() async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'requestIgnoreBatteryOptimizations',
      );
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Has the user been asked at least once on this install?
  static Future<bool> hasAsked(SharedPreferences prefs) async =>
      prefs.getBool(_askedKey) ?? false;

  /// Mark the user as asked. We record the result too so we don't pester
  /// them if they said no.
  static Future<void> markAsked(SharedPreferences prefs,
      {required bool granted}) async {
    await prefs.setBool(_askedKey, true);
    await prefs.setBool(_resultKey, granted);
  }

  /// First-run helper: returns true if we should prompt the user right
  /// now (not asked before AND not already ignoring). Caller is
  /// responsible for actually showing the prompt and calling
  /// [markAsked] afterwards.
  static Future<bool> shouldPrompt(SharedPreferences prefs) async {
    if (await hasAsked(prefs)) return false;
    if (await isIgnoring()) {
      // Already opted in — record it so we don't ask again.
      await markAsked(prefs, granted: true);
      return false;
    }
    return true;
  }
}
