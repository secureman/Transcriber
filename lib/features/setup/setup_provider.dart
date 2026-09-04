import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/config_provider.dart';
import '../../core/providers/shared_prefs_provider.dart';

Dio _plainDio() => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      validateStatus: (status) => status != null && status < 500,
    ));

enum SetupField { absUrl, absToken, backendUrl }

class SetupState {
  final bool testing;
  final String? error; // includes which URL failed
  final bool success;

  const SetupState({
    this.testing = false,
    this.error,
    this.success = false,
  });

  SetupState copyWith({
    bool? testing,
    String? error,
    bool? success,
    bool clearError = false,
  }) =>
      SetupState(
        testing: testing ?? this.testing,
        error: clearError ? null : (error ?? this.error),
        success: success ?? this.success,
      );
}

class SetupController extends Notifier<SetupState> {
  @override
  SetupState build() => const SetupState();

  Future<bool> testAndSave({
    required String absUrl,
    required String absToken,
    required String backendUrl,
  }) async {
    state = const SetupState(testing: true);

    // Normalize URLs (strip trailing slash).
    absUrl = absUrl.endsWith('/') ? absUrl.substring(0, absUrl.length - 1) : absUrl;
    backendUrl =
        backendUrl.endsWith('/') ? backendUrl.substring(0, backendUrl.length - 1) : backendUrl;

    // 1. Test backend health — only if provided (it is optional).
    if (backendUrl.isNotEmpty) {
      final backendError = await _testBackend(backendUrl);
      if (backendError != null) {
        state = SetupState(
          error: 'Transcription server unreachable: $backendUrl ($backendError)',
        );
        return false;
      }
    }

    // 2. Test ABS ping.
    final absError = await _testAbs(absUrl);
    if (absError != null) {
      state = SetupState(error: 'Audiobookshelf unreachable: $absUrl ($absError)');
      return false;
    }

    // 3. Save to prefs.
    final prefs = ref.read(sharedPrefsProvider);
    await AppConfig(
      absUrl: absUrl,
      absToken: absToken,
      backendUrl: backendUrl,
    ).saveToPrefs(prefs);
    ref.read(configRevisionProvider.notifier).state++;

    state = const SetupState(success: true);
    return true;
  }

  Future<String?> _testBackend(String url) async {
    try {
      final dio = _plainDio();
      final res = await dio.get('$url/api/health');
      if (res.statusCode == 200) return null;
      return 'HTTP ${res.statusCode}';
    } catch (e) {
      return e.toString().split('\n').first;
    }
  }

  Future<String?> _testAbs(String url) async {
    try {
      final dio = _plainDio();
      final res = await dio.get('$url/ping');
      if (res.statusCode == 200) return null;
      return 'HTTP ${res.statusCode}';
    } catch (e) {
      return e.toString().split('\n').first;
    }
  }
}

final setupControllerProvider =
    NotifierProvider<SetupController, SetupState>(SetupController.new);
