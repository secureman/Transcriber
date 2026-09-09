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

/// One-shot fetch of `GET /api/me` — the shared source for both the
/// current user's profile ([currentUserProvider]) and their per-book
/// listening progress ([absMediaProgressProvider]). Both watch this same
/// future so logging in / loading the library triggers a single request
/// instead of two. Returns null when offline or the token is invalid.
final _meResponseProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final abs = ref.read(absClientProvider);
  try {
    final res = await abs.get('/api/me');
    if (res.statusCode != 200 || res.data is! Map<String, dynamic>) {
      return null;
    }
    return res.data as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
});

/// The current ABS user for the configured token, or null when offline / the
/// token is invalid.
final currentUserProvider = FutureProvider<AbsUserInfo?>((ref) async {
  final json = await ref.watch(_meResponseProvider.future);
  if (json == null) return null;
  return AbsUserInfo.fromJson(json);
});

/// A single book's listening progress, as reported by ABS's
/// `mediaProgress` array (`GET /api/me`) — one entry per book the server
/// has a MediaProgress record for.
class AbsMediaProgressEntry {
  final String libraryItemId;
  final double duration;
  final double currentTime;
  final bool isFinished;

  /// Per-chapter "listened" mark set stored in
  /// `extraData.absListenChapters` by this app (see `_pushChapterMark` /
  /// `_pushBookMark` in read_chapters_provider.dart). Empty for books we
  /// haven't touched — ABS itself has no per-chapter concept.
  final Set<int> absListenChapters;

  /// Per-chapter playback position (seconds into each chapter) stored in
  /// `extraData.absChapterProgress` as `{ "0": 240.0, "1": 0, "2": 123.4 }`.
  /// Mirrored from the local `chapterPositionsProvider` so re-install /
  /// re-login restores not just which chapters are done but where in each
  /// chapter the user was — see `recordChapterPosition` in
  /// read_chapters_provider.dart.
  final Map<int, double> chapterProgress;

  const AbsMediaProgressEntry({
    required this.libraryItemId,
    required this.duration,
    required this.currentTime,
    required this.isFinished,
    this.absListenChapters = const <int>{},
    this.chapterProgress = const <int, double>{},
  });

  /// 0..1, computed client-side from currentTime/duration rather than
  /// trusted from ABS's stored `progress` field: the server only
  /// refreshes that field on an `isFinished` transition or when a caller
  /// explicitly sends `progress` in the PATCH payload, so it can go stale
  /// between those points even while currentTime/duration stay accurate.
  double get progressFraction =>
      duration <= 0 ? 0 : (currentTime / duration).clamp(0.0, 1.0);

  factory AbsMediaProgressEntry.fromJson(Map<String, dynamic> json) {
    final extra = json['extraData'] as Map<String, dynamic>?;
    final raw = extra?['absListenChapters'];
    final listened = <int>{};
    if (raw is List) {
      for (final e in raw) {
        if (e is num) {
          listened.add(e.toInt());
        } else if (e is String) {
          final v = int.tryParse(e);
          if (v != null) listened.add(v);
        }
      }
    }
    final positions = <int, double>{};
    final rawProgress = extra?['absChapterProgress'];
    if (rawProgress is Map) {
      rawProgress.forEach((k, v) {
        final i = k is num
            ? k.toInt()
            : (k is String ? int.tryParse(k) : null);
        if (i == null || i < 0) return;
        final d = v is num
            ? v.toDouble()
            : (v is String ? double.tryParse(v) : null);
        if (d == null || d < 0) return;
        positions[i] = d;
      });
    }
    return AbsMediaProgressEntry(
      libraryItemId: (json['libraryItemId'] as String?) ?? '',
      duration: (json['duration'] as num?)?.toDouble() ?? 0,
      currentTime: (json['currentTime'] as num?)?.toDouble() ?? 0,
      isFinished: json['isFinished'] == true,
      absListenChapters: listened,
      chapterProgress: positions,
    );
  }
}

/// Every book this user has listening progress for, keyed by library item
/// id. Sourced from `GET /api/me`'s `mediaProgress` array — the only
/// endpoint that reports progress for many books in a single request; the
/// library list endpoint (`/api/libraries/:id/items`) never includes
/// per-user progress, even when minified=0. Used to populate the progress
/// strip on the library screen and to bulk-restore "listened" badges for
/// finished books after a fresh install — see library_provider.dart.
final absMediaProgressProvider =
    FutureProvider<Map<String, AbsMediaProgressEntry>>((ref) async {
      final json = await ref.watch(_meResponseProvider.future);
      final list = json?['mediaProgress'] as List<dynamic>? ?? const [];
      final out = <String, AbsMediaProgressEntry>{};
      for (final e in list) {
        if (e is! Map<String, dynamic>) continue;
        final entry = AbsMediaProgressEntry.fromJson(e);
        if (entry.libraryItemId.isEmpty) continue;
        out[entry.libraryItemId] = entry;
      }
      return out;
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
      // ABS only recomputes its stored `progress` fraction on an
      // isFinished transition or when a caller sends this explicitly —
      // send it every time so the value other ABS clients read (web UI,
      // official apps) doesn't go stale between those transitions.
      'progress': (currentTimeSec / durationSec).clamp(0.0, 1.0),
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
