import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/shared_prefs_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/battery_optimization.dart';
import '../../core/widgets/error_banner.dart';
import '../../core/widgets/primary_button.dart';
import 'setup_provider.dart';
import 'widgets/custom_text_field.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _absUrlController = TextEditingController();
  final _absTokenController = TextEditingController();
  final _serverUrlController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // Local visibility toggle for the API key. Defaults to obscured so a
  // bystander can't read the token over the user's shoulder.
  bool _obscureApiKey = true;

  @override
  void dispose() {
    _absUrlController.dispose();
    _absTokenController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _testAndSave() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();

    final ok = await ref.read(setupControllerProvider.notifier).testAndSave(
          absUrl: _absUrlController.text.trim(),
          absToken: _absTokenController.text.trim(),
          serverUrl: _serverUrlController.text.trim(),
        );

    if (!mounted) return;
    if (!ok) return;

    // First-run: prompt the user to whitelist us from battery
    // optimization. This keeps the playback service alive in background
    // on aggressive OEMs. We do it after a successful test so we only
    // nag once setup is real.
    final prefs = ref.read(sharedPrefsProvider);
    if (await BatteryOptimization.shouldPrompt(prefs)) {
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text(
            'Keep audio playing in background',
            style: TextStyle(color: AppColors.textPrimary),
          ),
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(setupControllerProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              // Fill the viewport so the footer sits at the bottom of
              // the screen on tall devices, and scrolls naturally on
              // shorter ones (keyboard up).
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 56),
                      const _Header(),
                      const SizedBox(height: 40),
                      _FormSection(
                        urlController: _absUrlController,
                        tokenController: _absTokenController,
                        serverController: _serverUrlController,
                        formKey: _formKey,
                        obscureApiKey: _obscureApiKey,
                        onToggleObscure: () =>
                            setState(() => _obscureApiKey = !_obscureApiKey),
                        state: state,
                        onSubmit: _testAndSave,
                      ),
                      const Spacer(),
                      const SizedBox(height: 32),
                      const _Footer(),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ── Header ───────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(
            Icons.menu_book_rounded,
            color: AppColors.primary,
            size: 36,
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'EReader',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Read along with your audiobooks',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

// ── Form ─────────────────────────────────────────────────────────────────

class _FormSection extends StatelessWidget {
  final TextEditingController urlController;
  final TextEditingController tokenController;
  final TextEditingController serverController;
  final GlobalKey<FormState> formKey;
  final bool obscureApiKey;
  final VoidCallback onToggleObscure;
  final SetupState state;
  final VoidCallback onSubmit;

  const _FormSection({
    required this.urlController,
    required this.tokenController,
    required this.serverController,
    required this.formKey,
    required this.obscureApiKey,
    required this.onToggleObscure,
    required this.state,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CustomTextField(
            controller: urlController,
            label: 'Server URL',
            hint: 'http://192.168.1.10:13378',
            helperText: 'Your Audiobookshelf server address',
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Server URL is required' : null,
          ),
          const SizedBox(height: 20),
          CustomTextField(
            controller: tokenController,
            label: 'API Key',
            hint: 'Enter your API key',
            helperText: 'Settings → API Keys in Audiobookshelf',
            obscureText: obscureApiKey,
            textInputAction: TextInputAction.next,
            suffixIcon: IconButton(
              icon: Icon(
                obscureApiKey
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: AppColors.textSecondary,
                size: 20,
              ),
              onPressed: onToggleObscure,
              tooltip: obscureApiKey ? 'Show' : 'Hide',
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'API key is required' : null,
          ),
          const SizedBox(height: 20),
          CustomTextField(
            controller: serverController,
            label: 'Audiobook Server (optional)',
            hint: 'http://192.168.1.20:8001',
            helperText:
                'Accounts, reading progress & transcription — one server. '
                'Without it you can still browse and play, but progress '
                'sync, sign-in and the text view are unavailable.',
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => onSubmit(),
          ),
          if (state.error != null) ...[
            const SizedBox(height: 16),
            ErrorBanner(message: state.error!),
          ],
          const SizedBox(height: 24),
          PrimaryButton(
            loading: state.testing,
            onPressed: state.testing ? null : onSubmit,
            label: 'Connect',
          ),
        ],
      ),
    );
  }
}

// ── Footer ───────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _FooterItem(icon: Icons.wifi_off_rounded, label: 'Local'),
        SizedBox(width: 24),
        _FooterItem(icon: Icons.lock_outline_rounded, label: 'Private'),
        SizedBox(width: 24),
        _FooterItem(icon: Icons.cloud_off_outlined, label: 'No cloud'),
      ],
    );
  }
}

class _FooterItem extends StatelessWidget {
  final IconData icon;
  final String label;
  const _FooterItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}