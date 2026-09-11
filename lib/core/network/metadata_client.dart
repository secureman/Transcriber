import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/metadata_progress.dart';
import '../providers/config_provider.dart';
import '../providers/read_chapters_provider.dart';

/// Set the first time [startupProgressRestoreProvider] actually applies a
/// bulk restore; guards against re-running the merge when the provider is
/// re-created after a config edit. Process-lifetime on purpose.
var _startupRestoreDone = false;

/// Dio instance pointed at the metadata server. Carries the Audiobookshelf
/// token as an `X-API-Key` header — there is no login in this app; the key
/// is whatever the user stored during setup ([configProvider.absToken]) and
/// the header is re-derived whenever that config changes.
final metadataClientProvider = Provider<Dio>((ref) {
  final config = ref.watch(configProvider);
  final token = config.absToken;
  return Dio(
    BaseOptions(
      baseUrl: config.serverUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      headers: {
        if (token.isNotEmpty) 'X-API-Key': token,
      },
      validateStatus: (status) => status != null && status < 500,
    ),
  );
});

/// One-shot bulk fetch of all listen progress from the metadata server.
/// The Flutter client uses this to populate its three local stores
/// (listened marks, per-chapter positions, continue-reading bookmarks) in
/// a single round trip. Returns null when offline / unconfigured / the
/// server errored (e.g. the stored key no longer validates against ABS).
///
/// Re-runs automatically when the config changes: it watches the config,
/// so editing the server URL or API token re-arms the future against the
/// freshly-built Dio instance.
final metadataProgressProvider = FutureProvider<MetadataBulkProgress?>((ref) async {
  final config = ref.watch(configProvider);
  final token = config.absToken;
  if (!config.serverConfigured || token.isEmpty) return null;
  final dio = ref.watch(metadataClientProvider);
  try {
    final res = await dio.get('/api/progress');
    if (res.statusCode != 200) return null;
    return MetadataBulkProgress.fromJson(res.data);
  } catch (_) {
    return null;
  }
});

/// Once-per-launch startup restore: fetches the bulk progress snapshot and
/// merges it into [ReadChaptersController] via
/// [ReadChaptersController.restoreFromMetadataBulk] so listened marks /
/// chapter positions / continue-reading survive across devices. Watched
/// from [EReaderApp] so it starts as soon as the config is ready; the
/// [_startupRestoreDone] flag makes the merge itself one-shot even if this
/// provider is rebuilt (config edits, invalidate) or re-watched.
final startupProgressRestoreProvider =
    FutureProvider<bool>((ref) async {
  if (_startupRestoreDone) return true;
  final progress = await ref.watch(metadataProgressProvider.future);
  if (progress == null || _startupRestoreDone) return false;
  await ref
      .read(readChaptersProvider.notifier)
      .restoreFromMetadataBulk(progress);
  _startupRestoreDone = true;
  return true;
});