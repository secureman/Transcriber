import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/shared_prefs_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/battery_optimization.dart';
import 'setup_provider.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _absUrlController = TextEditingController();
  final _absTokenController = TextEditingController();
  final _backendUrlController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _absUrlController.dispose();
    _absTokenController.dispose();
    _backendUrlController.dispose();
    super.dispose();
  }

  Future<void> _testAndSave() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    final ok = await ref.read(setupControllerProvider.notifier).testAndSave(
          absUrl: _absUrlController.text.trim(),
          absToken: _absTokenController.text.trim(),
          backendUrl: _backendUrlController.text.trim(),
        );

    if (!mounted) return;
    if (ok) {
      // First-run: prompt the user to whitelist us from battery
      // optimization. This keeps the playback service alive in
      // background on aggressive OEMs. We do it after a successful
      // test so we only nag once setup is real.
      final prefs = ref.read(sharedPrefsProvider);
      if (await BatteryOptimization.shouldPrompt(prefs)) {
        // Show a small confirmation first so the dialog doesn't come
        // out of nowhere. The user can decline — we won't ask again.
        final accepted = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text('Keep audio playing in background',
                style: TextStyle(color: AppColors.textPrimary)),
            content: const Text(
              'Android may pause the audiobook when the app is in the '
              'background. Whitelist EReader from battery optimization '
              'to keep playback uninterrupted.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Open settings'),
              ),
            ],
          ),
        );
        if (accepted == true) {
          final granted = await BatteryOptimization.requestIgnore();
          await BatteryOptimization.markAsked(prefs, granted: granted);
        } else {
          await BatteryOptimization.markAsked(prefs, granted: false);
        }
      }

      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(setupControllerProvider);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 48),
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppColors.cardRadius),
                      border: Border.all(color: AppColors.primary, width: 2),
                    ),
                    child: const Icon(Icons.menu_book_rounded,
                        color: AppColors.primary, size: 36),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'EReader',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontSize: 28,
                          color: AppColors.primary,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Read along with your audiobooks',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 48),
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
                  const SizedBox(height: 32),
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
                    onPressed: state.testing ? null : _testAndSave,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: state.testing
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppColors.highlightText,
                            ),
                          )
                        : state.success
                            ? const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.check_circle,
                                      color: AppColors.highlightText),
                                  SizedBox(width: 8),
                                  Text('Connected'),
                                ],
                              )
                            : const Text('TEST & SAVE'),
                  ),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
