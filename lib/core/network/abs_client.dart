import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/config_provider.dart';

/// Dio instance pointed at the Audiobookshelf server with Bearer auth.
final absClientProvider = Provider<Dio>((ref) {
  final config = ref.watch(configProvider);
  return Dio(
    BaseOptions(
      baseUrl: config.absUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        if (config.absToken.isNotEmpty)
          'Authorization': 'Bearer ${config.absToken}',
      },
      validateStatus: (status) => status != null && status < 500,
    ),
  );
});
