import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/providers/shared_prefs_provider.dart';
import 'features/player/audio_handler.dart';
import 'features/player/player_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  // Initialize audio_service for background playback + lock screen controls.
  final audioHandler = await AudioService.init(
    builder: () => AudiobookAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.ereader.app.playback',
      androidNotificationChannelName: 'Audiobook playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const EReaderApp(),
    ),
  );
}
