import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/abs_client.dart';
import '../../core/offline/offline_provider.dart';
import '../../models/abs_item.dart';

class LibraryState {
  final List<AbsItem> items;
  final int page;
  final bool hasMore;
  final bool isLoadingMore;

  /// True when [items] came from the offline downloads (server unreachable).
  final bool servedFromCache;

  const LibraryState({
    this.items = const [],
    this.page = 0,
    this.hasMore = true,
    this.isLoadingMore = false,
    this.servedFromCache = false,
  });

  LibraryState copyWith({
    List<AbsItem>? items,
    int? page,
    bool? hasMore,
    bool? isLoadingMore,
    bool? servedFromCache,
  }) =>
      LibraryState(
        items: items ?? this.items,
        page: page ?? this.page,
        hasMore: hasMore ?? this.hasMore,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        servedFromCache: servedFromCache ?? this.servedFromCache,
      );
}

class LibraryController extends AsyncNotifier<LibraryState> {
  @override
  Future<LibraryState> build() => _fetchPage(0);

  Future<LibraryState> _fetchPage(int page) async {
    try {
      return await _fetchFromServer(page);
    } catch (e) {
      // Server unreachable — fall back to downloaded books so the library
      // still works offline.
      if (page == 0) {
        final offlineBooks =
            ref.read(offlineStoreProvider).books.values.toList();
        if (offlineBooks.isNotEmpty) {
          final items = offlineBooks.map((b) {
            return AbsItem.fromJson(
              jsonDecode(b.itemJson) as Map<String, dynamic>,
            );
          }).toList();
          return LibraryState(
            items: items,
            page: 0,
            hasMore: false,
            servedFromCache: true,
          );
        }
      }
      rethrow;
    }
  }

  Future<LibraryState> _fetchFromServer(int page) async {
    final dio = ref.read(absClientProvider);

    // Pick the first library.
    final libsRes = await dio.get('/api/libraries');
    if (libsRes.statusCode != 200) {
      throw Exception('Failed to load libraries (HTTP ${libsRes.statusCode})');
    }
    final libraries = (libsRes.data['libraries'] as List<dynamic>? ?? []);
    if (libraries.isEmpty) {
      throw Exception('No libraries found on the server');
    }
    final libraryId = (libraries.first as Map<String, dynamic>)['id'] as String;

    final itemsRes = await dio.get(
      '/api/libraries/$libraryId/items',
      queryParameters: {'limit': 50, 'page': page, 'minified': '1'},
    );
    if (itemsRes.statusCode != 200) {
      throw Exception(
          'Failed to load items (HTTP ${itemsRes.statusCode})');
    }
    final results =
        (itemsRes.data['results'] as List<dynamic>? ?? []);
    final newItems = results
        .map((e) => AbsItem.fromLibraryJson(e as Map<String, dynamic>))
        .toList();

    final prev = state.valueOrNull ?? const LibraryState();
    final merged = page == 0
        ? newItems
        : [...prev.items, ...newItems];
    return LibraryState(
      items: merged,
      page: page,
      hasMore: newItems.length >= 50,
      servedFromCache: false,
    );
  }

  Future<void> refresh() async {
    state = const AsyncLoading<LibraryState>().copyWithPrevious(
      state,
      isRefresh: true,
    );
    state = await AsyncValue.guard(() => _fetchPage(0));
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.isLoadingMore) return;
    state = AsyncData(current.copyWith(isLoadingMore: true));
    try {
      final nextPage = await _fetchPage(current.page + 1);
      state = AsyncData(nextPage);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}

final libraryItemsProvider =
    AsyncNotifierProvider<LibraryController, LibraryState>(
        LibraryController.new);
