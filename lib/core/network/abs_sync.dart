import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/config_provider.dart';
import 'abs_client.dart';

/// SharedPreferences key holding this install's stable device id.
const _deviceIdKey = 'abs_device_id';

/// Generates (once) and persists a stable device id so Audiobookshelf can
/// attribute synced listening progress to this install.
Future<String> getOrCreateDeviceId(SharedPreferences prefs) async {
  var id = prefs.getString(_deviceIdKey);
  if (id == null || id.isEmpty) {
    final r = Random();
    id =
        '${DateTime.now().millisecondsSinceEpoch}'
        '-${r.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0')}'
        '-${r.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    await prefs.setString(_deviceIdKey, id);
  }
  return id;
}

/// The user backing the configured ABS token (GET /api/me).
class AbsUserInfo {
  final String id;
  final String username;
  final String name;
  final String? avatar; // data URL (base64) or file path

  const AbsUserInfo({
    required this.id,
    required this.username,
    required this.name,
    this.avatar,
  });

  factory AbsUserInfo.fromJson(Map<String, dynamic> json) => AbsUserInfo(
    id: (json['id'] as String?) ?? '',
    username: (json['username'] as String?) ?? '',
    name: (json['name'] as String?) ?? '',
    avatar: json['avatar'] as String?,
  );

  String get displayName => name.isNotEmpty ? name : username;
}

/// The current ABS user for the configured token, or null when offline / the
/// token is invalid.
final currentUserProvider = FutureProvider<AbsUserInfo?>((ref) async {
  final abs = ref.read(absClientProvider);
  try {
    final res = await abs.get('/api/me');
    if (res.statusCode != 200 || res.data is! Map<String, dynamic>) {
      return null;
    }
    return AbsUserInfo.fromJson(res.data as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
});

/// Pushes playback progress to Audiobookshelf via the MediaProgress upsert
/// endpoint, `PATCH /api/me/progress/:libraryItemId`, which has existed on
/// every ABS v2.4+ release (and still exists on master). The handler spreads
/// the request body straight onto the user's media-progress record, so we
/// send the media-progress fields directly — NOT wrapped in a `progress`
/// key, and without the old `/api/sync/local-media-progress` sync payload
/// (deviceId/journalMode/audioTracks/libraryItem) that the modern server
/// doesn't expect.
class AbsProgressSyncer {
  AbsProgressSyncer(this.ref);

  final Ref ref;

  Future<bool> reportProgress({
    required String itemId,
    required double durationSec,
    required double currentTimeSec,
    bool isFinished = false,
    int? startedAt,
    int? finishedAt,
  }) async {
    final config = ref.read(configProvider);
    if (!config.isConfigured || itemId.isEmpty) return false;
    if (durationSec <= 0) return false;

    final body = <String, dynamic>{
      'isFinished': isFinished,
      'duration': durationSec.round(),
      'currentTime': currentTimeSec <= 0 ? 0 : currentTimeSec,
      'startedAt': startedAt,
      'finishedAt': finishedAt,
    };

    try {
      final abs = ref.read(absClientProvider);
      final res = await abs.patch('/api/me/progress/$itemId', data: body);
      if (res.statusCode == null || res.statusCode! >= 300) {
        final status = res.statusCode;
        // 4xx responses don't throw under this Dio config (validateStatus
        // < 500), so handle them here. These are permanent contract errors —
        // don't retry forever against an ABS that doesn't support them.
        if (status == 400 || status == 404 || status == 405 || status == 422) {
          return _unsupported();
        }
        return false;
      }
      return true;
    } catch (e) {
      // Network-level failure (timeout, connection refused) — callers decide
      // whether to back off and retry.
      final status = (e is DioException) ? e.response?.statusCode : null;
      if (status == 400 || status == 404 || status == 405 || status == 422) {
        return _unsupported();
      }
      return false;
    }
  }

  /// A permanent contract error — the caller treats this the same as a
  /// non-2xx so it can stop hammering an incompatible ABS.
  bool _unsupported() => false;
}

final progressSyncProvider = Provider<AbsProgressSyncer>(
  (ref) => AbsProgressSyncer(ref),
);
