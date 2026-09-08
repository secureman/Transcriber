import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../models/abs_item.dart';
import 'library_provider.dart';
import 'widgets/book_card.dart';
import 'widgets/book_list_tile.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  @override
  Widget build(BuildContext context) {
    final libraryAsync = ref.watch(libraryItemsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _openSearch(context),
          ),
          const _ViewModeToggle(),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: libraryAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
        error: (error, stack) => _ErrorView(
          message: error.toString(),
          onRetry: () => ref.read(libraryItemsProvider.notifier).refresh(),
        ),
        data: (state) {
          if (state.items.isEmpty) {
            return const Center(
              child: Text(
                'No books found',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            );
          }

          final viewMode = ref.watch(libraryViewModeProvider);
          return Column(
            children: [
              if (state.servedFromCache) ...[
                _OfflineBanner(
                  onRetry: () =>
                      ref.read(libraryItemsProvider.notifier).refresh(),
                ),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: RefreshIndicator(
                  color: AppColors.primary,
                  backgroundColor: AppColors.surface,
                  onRefresh: () =>
                      ref.read(libraryItemsProvider.notifier).refresh(),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels >= n.metrics.maxScrollExtent - 400) {
                        ref.read(libraryItemsProvider.notifier).loadMore();
                      }
                      return false;
                    },
                    child: viewMode == LibraryViewMode.list
                        ? _BooksList(items: state.items)
                        : _BooksGrid(items: state.items),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openSearch(BuildContext context) {
    showSearch(
      context: context,
      delegate: _BookSearchDelegate(
        items: ref.read(libraryItemsProvider).valueOrNull?.items ?? const [],
      ),
    );
  }
}

/// App-bar toggle between the compact ABS-style list and the covers grid.
/// The choice persists (see libraryViewModeProvider).
class _ViewModeToggle extends ConsumerWidget {
  const _ViewModeToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(libraryViewModeProvider);
    final isList = mode == LibraryViewMode.list;
    return IconButton(
      icon: Icon(isList ? Icons.grid_view_rounded : Icons.view_list_rounded),
      tooltip: isList ? 'Switch to grid view' : 'Switch to list view',
      onPressed: () => ref
          .read(libraryViewModeProvider.notifier)
          .set(isList ? LibraryViewMode.grid : LibraryViewMode.list),
    );
  }
}

/// Compact ABS-style rows (the default library layout).
class _BooksList extends StatelessWidget {
  final List<AbsItem> items;

  const _BooksList({required this.items});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      itemCount: items.length,
      itemBuilder: (context, index) => BookListTile(item: items[index]),
    );
  }
}

/// The original covers grid. Fluid column count (≈160px per cover, clamped
/// 2–6) adapts continuously to any width, and the text block scales with
/// the system font setting instead of assuming a fixed pixel budget, so
/// cards readjust properly on phones with large display sizes.
class _BooksGrid extends StatelessWidget {
  final List<AbsItem> items;

  const _BooksGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        const spacing = 16.0;
        const padding = 16.0;
        final crossAxisCount = (width / 160)
            .clamp(2.0, 6.0)
            .floor()
            .clamp(2, 6);
        final itemWidth =
            (width - padding * 2 - spacing * (crossAxisCount - 1)) /
            crossAxisCount;
        // Measure the actual on-screen text-block height (title, author,
        // spacer, progress bar) rather than hard-coding ~66px, so large
        // system font scales can't overflow the card.
        final textBlock = BookCard.textBlockHeight(context);
        final childAspectRatio = itemWidth / (itemWidth * 1.32 + textBlock);

        return GridView.builder(
          padding: const EdgeInsets.all(padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 20,
            crossAxisSpacing: spacing,
            childAspectRatio: childAspectRatio,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => BookCard(item: items[index]),
        );
      },
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  final VoidCallback onRetry;

  const _OfflineBanner({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.wifi_off_rounded,
            color: AppColors.textSecondary,
            size: 16,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Server unreachable · showing downloaded books',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off,
              color: AppColors.textSecondary,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              'Could not reach the server\n$message',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _BookSearchDelegate extends SearchDelegate<AbsItem?> {
  final List<AbsItem> items;

  _BookSearchDelegate({required this.items});

  @override
  ThemeData appBarTheme(BuildContext context) {
    final theme = AppTheme.dark;
    return theme.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        hintStyle: TextStyle(color: AppColors.textSecondary),
        border: InputBorder.none,
      ),
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) => [
    IconButton(icon: const Icon(Icons.close), onPressed: () => query = ''),
  ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    onPressed: () => close(context, null),
  );

  @override
  Widget buildResults(BuildContext context) => _resultsList();

  @override
  Widget buildSuggestions(BuildContext context) => _resultsList();

  Widget _resultsList() {
    final q = query.toLowerCase();
    final results = q.isEmpty
        ? items
        : items
              .where(
                (i) =>
                    i.title.toLowerCase().contains(q) ||
                    i.author.toLowerCase().contains(q),
              )
              .toList();
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final item = results[index];
        return ListTile(
          title: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textPrimary),
          ),
          subtitle: Text(
            item.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          onTap: () => close(context, item),
        );
      },
    );
  }
}
