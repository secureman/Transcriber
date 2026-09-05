import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/abs_item.dart';
import '../providers/config_provider.dart';
import '../providers/shared_prefs_provider.dart';
import 'abs_client.dart';

/// SharedPreferences key holding this install's stable device id.
const _deviceIdKey = 'abs_device_id';

/// Generates (once) and persists a stable device id so Audiobookshelf can
/// attribute synced listening progress to this install.
Future<String> getOrCreateDeviceId(SharedPreferences prefs) async {
  var id = prefs.getString(_deviceIdKey);
  if (id == null || id.isEmpty) {
    final r = Random();
    id = '${DateTime.now().millisecondsSinceEpoch}'
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

/// Pushes playback progress to Audiobookshelf (POST /api/sync/local-media-
/// progress) so it stays consistent across the web player, other clients and
/// the ABS admin UI.
class AbsProgressSyncer {
  AbsProgressSyncer(this.ref);

  final Ref ref;
  String? _deviceId;
  bool _disabled = false;

  Future<String> _device() async {
    var id = _deviceId;
    if (id == null) {
      id = await getOrCreateDeviceId(ref.read(sharedPrefsProvider));
      _deviceId = id;
    }
    return id;
  }

  /// Reports a position for [itemId]. Returns true when the server accepted
  /// it. After certain errors the syncer disables itself to avoid hammering
  /// an incompatible/older ABS server every few seconds.
  Future<bool> reportProgress({
    required String itemId,
    required String mediaId,
    required double durationSec,
    required double currentTimeSec,
    bool isFinished = false,
    int? startedAt,
    int? finishedAt,
    List<Map<String, dynamic>> audioTracks = const [],
    Map<String, dynamic>? libraryItem,
  }) async {
    if (_disabled) return false;
    final config = ref.read(configProvider);
    if (!config.isConfigured || itemId.isEmpty || mediaId.isEmpty) return false;
    if (durationSec <= 0) return false;

    final deviceId = await _device();
    final body = <String, dynamic>{
      'itemId': itemId,
      'deviceId': deviceId,
      'progress': {
        'id': 'local-$deviceId-$itemId',
        'deviceId': deviceId,
        'libraryItemId': itemId,
        'mediaId': mediaId,
        'isFinished': isFinished,
        'duration': durationSec.round(),
        'currentTime': currentTimeSec <= 0 ? 0 : currentTimeSec,
        'startedAt': startedAt,
        'finishedAt': finishedAt,
        'journalMode': 'sync',
        'audioTracks': audioTracks,
        'libraryItem': libraryItem,
        'episode': null,
      },
    };

    try {
      final abs = ref.read(absClientProvider);
      final res = await abs.post('/api/sync/local-media-progress', data: body);
      return res.statusCode != null && res.statusCode! < 300;
    } catch (e) {
      final status = (e is DioException) ? e.response?.statusCode : null;
      // Endpoint/payload not supported on this ABS version — stop retrying
      // every few seconds for the rest of this session.
      if (status == 400 || status == 404 || status == 405 || status == 422) {
        _disabled = true;
      }
      return false;
    }
  }
}

final progressSyncProvider =
    Provider<AbsProgressSyncer>((ref) => AbsProgressSyncer(ref));

/// Minified `libraryItem` payload ABS expects inside the sync body.
Map<String, dynamic> buildMinifiedLibraryItem(AbsItem item) => {
      'id': item.id,
      'media': {
        'id': item.mediaId,
        'metadata': {
          'title': item.title,
          'authorName': item.author,
        },
        'duration': item.duration,
        'numAudioFiles': item.audioFiles.length,
        'numChapters': item.chapters.length,
        'chapters': [
          for (final c in item.chapters)
            {
              'id': c.id,
              'start': c.start,
              'end': c.end,
              'title': c.title,
            },
        ],
        'hasEmbeddedCover': item.coverPath.isNotEmpty,
      },
    };

/// One `audioTracks` entry for the sync body.
Map<String, dynamic> buildAudioTrack({
  required int index,
  required String filename,
  required String url,
}) =>
    {
      'index': index,
      'title': filename,
      'contentUrl': url,
      'mimeType': _mimeFor(filename),
    };

String _mimeFor(String filename) {
  final ext = filename.contains('.')
      ? filename.split('.').last.toLowerCase()
      : '';
  switch (ext) {
    case 'mp3':
      return 'audio/mpeg';
    case 'm4b':
    case 'm4a':
    case 'aac':
    case 'mp4':
      return 'audio/mp4';
    case 'flac':
      return 'audio/flac';
    case 'ogg':
      return 'audio/ogg';
    case 'opus':
      return 'audio/opus';
    case 'wav':
      return 'audio/wav';
    case 'webm':
      return 'audio/webm';
    default:
      return 'audio/mpeg';
  }
}