import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers/config_provider.dart';
import 'core/theme/app_theme.dart';
import 'features/book_detail/book_detail_screen.dart';
import 'features/library/library_screen.dart';
import 'features/player/player_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/setup/setup_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = ValueNotifier(0);
  ref.listen(configRevisionProvider, (_, _) => refreshNotifier.value++);
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    refreshListenable: refreshNotifier,
    initialLocation: '/',
    redirect: (context, state) {
      final config = ref.read(configProvider);
      final isSetup = state.matchedLocation == '/setup';
      if (!config.isConfigured && !isSetup) return '/setup';
      if (config.isConfigured && isSetup) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/setup',
        builder: (context, state) => const SetupScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => const LibraryScreen(),
      ),
      GoRoute(
        path: '/book/:id',
        builder: (context, state) => BookDetailScreen(
          itemId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/player/:id/:chapterIndex',
        builder: (context, state) => PlayerScreen(
          itemId: state.pathParameters['id']!,
          chapterIndex: int.tryParse(state.pathParameters['chapterIndex']!) ?? 0,
        ),
      ),
    ],
  );
});

class EReaderApp extends ConsumerWidget {
  const EReaderApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'EReader',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: router,
    );
  }
}
