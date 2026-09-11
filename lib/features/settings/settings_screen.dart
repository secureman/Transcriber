import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/offline/offline_provider.dart';
import '../../core/providers/config_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/primary_button.dart';
import '../library/library_provider.dart';
import '../setup/setup_provider.dart';
import '../setup/widgets/custom_text_field.dart';

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
  final _serverUrlController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _prefilled = false;

  // Local visibility toggle for the API key. Mirrors the setup screen so
  // both flows feel consistent when editing existing credentials.
  bool _obscureApiKey = true;

  @override
  void dispose() {
    _absUrlController.dispose();
    _absTokenController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  void _prefill() {
    if (_prefilled) return;
    _prefilled = true;
    final config = ref.read(configProvider);
    _absUrlController.text = config.absUrl;
    _absTokenController.text = config.absToken;
    _serverUrlController.text = config.serverUrl;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    final ok = await ref.read(setupControllerProvider.notifier).testAndSave(
          absUrl: _absUrlController.text.trim(),
          absToken: _absTokenController.text.trim(),
          serverUrl: _serverUrlController.text.trim(),
        );

    if (!mounted) return;
    if (!ok) return;

    // Server settings changed → refresh data fetched with the old config.
    ref.invalidate(libraryItemsProvider);
    // The server URL may have changed too — the Dio client reads
    // it through configProvider, and the bulk fetch re-arms on next read.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved')),
    );
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    _prefill();
    final state = ref.watch(setupControllerProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SectionLabel('Server Configuration'),
                const SizedBox(height: 12),
                CustomTextField(
                  controller: _absUrlController,
                  label: 'Server URL',
                  hint: 'http://192.168.1.10:13378',
                  helperText: 'Your Audiobookshelf server address',
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Server URL is required'
                      : null,
                ),
                const SizedBox(height: 20),
                CustomTextField(
                  controller: _absTokenController,
                  label: 'API Key',
                  hint: 'Enter your API key',
                  helperText: 'Settings → API Keys in Audiobookshelf',
                  obscureText: _obscureApiKey,
                  textInputAction: TextInputAction.next,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureApiKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: AppColors.textSecondary,
                      size: 20,
                    ),
                    onPressed: () =>
                        setState(() => _obscureApiKey = !_obscureApiKey),
                    tooltip: _obscureApiKey ? 'Show' : 'Hide',
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'API key is required'
                      : null,
                ),
                const SizedBox(height: 20),
                CustomTextField(
                  controller: _serverUrlController,
                  label: 'Audiobook Server',
                  hint: 'http://192.168.1.20:8001',
                  helperText:
                      'Reading progress & transcription — one server. No '
                      'account needed; your API key identifies you.',
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _save(),
                ),
                if (state.error != null) ...[
                  const SizedBox(height: 16),
                  ErrorBanner(message: state.error!),
                ],
                const SizedBox(height: 24),
                PrimaryButton(
                  loading: state.testing,
                  onPressed: state.testing ? null : _save,
                  label: 'Save',
                ),
                const SizedBox(height: 32),
                const _OfflineStorageSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.primary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    );
  }
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
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
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