import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden in main() with the real SharedPreferences instance so that
/// synchronous reads are possible in providers (e.g. router redirect).
final sharedPrefsProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('sharedPrefsProvider must be overridden in main');
});
