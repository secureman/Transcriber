import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/config_provider.dart';

/// Dio instance pointed at the transcription backend.
final backendClientProvider = Provider<Dio>((ref) {
  final config = ref.watch(configProvider);
  return Dio(
    BaseOptions(
      baseUrl: config.backendUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      validateStatus: (status) => status != null && status < 500,
    ),
  );
});
