import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/config_provider.dart';

/// Dio instance pointed at the unified audiobook-server (transcription
/// half: /api/metadata, /api/transcribe, /api/jobs, /api/vtt). Same host
/// as [metadataClientProvider] — kept separate so each can carry its own
/// timeouts/token without coupling the consumers.
final backendClientProvider = Provider<Dio>((ref) {
  final config = ref.watch(configProvider);
  return Dio(
    BaseOptions(
      baseUrl: config.serverUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      validateStatus: (status) => status != null && status < 500,
    ),
  );
});
