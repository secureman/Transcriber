import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
              ],
            ),
          ),
        ),
      ),
    );
  }
}