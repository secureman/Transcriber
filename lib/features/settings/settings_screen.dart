import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/abs_sync.dart';
import '../../core/offline/offline_provider.dart';
import '../../core/providers/config_provider.dart';
import '../../core/theme/app_theme.dart';
import '../library/library_provider.dart';
import '../setup/setup_provider.dart';

/// Editable ABS / transcription server settings. Reuses the same health-check
/// controller as the setup screen.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _absUrlController = TextEditingController();
  final _absTokenController = TextEditingController();
  final _backendUrlController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _prefilled = false;

  @override
  void dispose() {
    _absUrlController.dispose();
    _absTokenController.dispose();
    _backendUrlController.dispose();
    super.dispose();
  }

  void _prefill() {
    if (_prefilled) return;
    _prefilled = true;
    final config = ref.read(configProvider);
    _absUrlController.text = config.absUrl;
    _absTokenController.text = config.absToken;
    _backendUrlController.text = config.backendUrl;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    final ok = await ref.read(setupControllerProvider.notifier).testAndSave(
          absUrl: _absUrlController.text.trim(),
          absToken: _absTokenController.text.trim(),
          backendUrl: _backendUrlController.text.trim(),
        );

    if (!mounted) return;
    if (ok) {
      // Server settings changed → refresh data fetched with the old config.
      ref.invalidate(libraryItemsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    _prefill();
    final state = ref.watch(setupControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SignedInCard(),
                const SizedBox(height: 20),
                const Text(
                  'Server Configuration',
                  style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _absUrlController,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'ABS Server URL',
                    hintText: 'http://192.168.1.10:13378',
                    prefixIcon: Icon(Icons.dns_outlined,
                        color: AppColors.textSecondary),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _absTokenController,
                  obscureText: true,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'ABS API Token',
                    hintText: 'ey...',
                    prefixIcon: Icon(Icons.key_outlined,
                        color: AppColors.textSecondary),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _backendUrlController,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Transcription Server URL (optional)',
                    hintText: 'http://192.168.1.10:8000',
                    prefixIcon:
                        Icon(Icons.graphic_eq, color: AppColors.textSecondary),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'The transcription server is optional. Without it you can '
                  'still browse and play, but the word-by-word text view and '
                  'transcription are unavailable.',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 24),
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline,
                            color: AppColors.error, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            state.error!,
                            style: const TextStyle(color: AppColors.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                FilledButton(
                  onPressed: state.testing ? null : _save,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  child: state.testing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.highlightText,
                          ),
                        )
                      : const Text('TEST & SAVE'),
                ),
                const SizedBox(height: 24),
                const _OfflineStorageSection(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SignedInCard extends ConsumerWidget {
  const _SignedInCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(currentUserProvider);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        border: Border.all(color: AppColors.surfaceElevated),
      ),
      child: userAsync.when(
        loading: () => const Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
            SizedBox(width: 12),
            Text(
              'Connecting to Audiobookshelf…',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
        error: (_, _) => _row(
          icon: Icons.cloud_off_rounded,
          title: 'Can’t verify user',
          subtitle: 'Check the server and try again',
        ),
        data: (user) {
          if (user == null) {
            return _row(
              icon: Icons.person_off_outlined,
              title: 'Not signed in',
              subtitle: 'Check your ABS URL & token',
            );
          }
          return Row(
            children: [
              _Avatar(avatar: user.avatar, name: user.displayName),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${user.username} · listening sync on',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh user',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh,
                    size: 18, color: AppColors.textSecondary),
                onPressed: () => ref.invalidate(currentUserProvider),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Row(
      children: [
        Icon(icon, color: AppColors.textSecondary, size: 26),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 15)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? avatar;
  final String name;

  const _Avatar({required this.avatar, required this.name});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: _image(),
    );
  }

  Widget _image() {
    final data = avatar;
    if (data != null && data.startsWith('data:image') && data.contains(',')) {
      try {
        final bytes = base64Decode(data.split(',').last);
        return ClipOval(
          child: Image.memory(
            bytes,
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _fallback(),
          ),
        );
      } catch (_) {
        return _fallback();
      }
    }
    return _fallback();
  }

  Widget _fallback() => Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: AppColors.surfaceElevated,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          name.isEmpty ? '?' : name[0].toUpperCase(),
          style: const TextStyle(
            color: AppColors.primary,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
      );
}

class _OfflineStorageSection extends ConsumerWidget {
  const _OfflineStorageSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(offlineStoreProvider);
    if (store.books.isEmpty) return const SizedBox.shrink();

    final totalBytes =
        store.books.values.fold<int>(0, (sum, b) => sum + b.sizeBytes);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppColors.cardRadius),
        border: Border.all(color: AppColors.surfaceElevated),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Offline Downloads',
            style: TextStyle(
              color: AppColors.primary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.offline_pin_rounded,
                  color: AppColors.textSecondary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${store.books.length} '
                      '${store.books.length == 1 ? 'book' : 'books'} stored',
                      style: const TextStyle(
                          color: AppColors.textPrimary, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_fmtBytes(totalBytes)} · playable without a server',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => _confirmAndClearAll(context, ref),
                child: const Text('Clear all'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndClearAll(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Clear all downloads?',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text(
          'This deletes every downloaded audiobook and frees up storage. '
          'Playback needs the server again.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(offlineStoreProvider.notifier).clearAll();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All downloads cleared')),
    );
  }
}

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}