import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers/config_provider.dart';
import 'core/network/metadata_client.dart';
import 'core/theme/app_theme.dart';
import 'features/book_detail/book_detail_screen.dart';
import 'features/library/library_screen.dart';
import 'features/player/player_screen.dart';
import 'features/player/widgets/mini_player_bar.dart';
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
      final location = state.matchedLocation;
      final isSetup = location == '/setup';
      // No server config yet → first-run setup.
      if (!config.isConfigured) return isSetup ? null : '/setup';
      // Configured but still on the setup screen → home.
      if (isSetup) return '/';
      return null;
    },
    routes: [
      // Outside the shell: full-screen setup flow.
      GoRoute(
        path: '/setup',
        builder: (context, state) => const SetupScreen(),
      ),
      // Shell screens (library / book detail / settings) share the bottom
      // mini player bar, so playback continues after leaving the player.
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const HomeScreen(),
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
        ],
      ),
      // Outside the shell: the full-screen player replaces everything.
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

/// Wraps the shell screens with the persistent mini player bar at the bottom.
class AppShell extends StatelessWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: child),
          const MiniPlayerBar(),
        ],
      ),
    );
  }
}

class EReaderApp extends ConsumerWidget {
  const EReaderApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Fire the once-per-launch listen-progress restore whenever the backend
    // client is ready (config present). The provider dedupes itself —
    // re-watching it from every shell rebuild is free.
    ref.watch(startupProgressRestoreProvider);
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Echoread',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: router,
    );
  }
}
