import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../models/abs_item.dart';
import 'library_provider.dart';
import 'widgets/book_card.dart';

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
              child: Text('No books found',
                  style: TextStyle(color: AppColors.textSecondary)),
            );
          }

          return RefreshIndicator(
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
              child: GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 16,
                  // Taller than wide: cover + title + author + progress.
                  childAspectRatio: 0.52,
                ),
                itemCount: state.items.length,
                itemBuilder: (context, index) =>
                    BookCard(item: state.items[index]),
              ),
            ),
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
            const Icon(Icons.cloud_off,
                color: AppColors.textSecondary, size: 48),
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
            .where((i) =>
                i.title.toLowerCase().contains(q) ||
                i.author.toLowerCase().contains(q))
            .toList();
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final item = results[index];
        return ListTile(
          title: Text(item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textPrimary)),
          subtitle: Text(item.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textSecondary)),
          onTap: () => close(context, item),
        );
      },
    );
  }
}
