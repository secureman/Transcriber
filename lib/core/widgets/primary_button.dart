import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Primary call-to-action button used across the auth/setup flows.
///
/// Renders a full-width orange pill that darkens on press (0.97 scale +
/// Material ripple), drops to 50% opacity when disabled, and swaps the
/// label for a `CircularProgressIndicator` while [loading]. Wrapped in
/// `Semantics` so screen readers still see a proper button.
class PrimaryButton extends StatefulWidget {
  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.loading,
    required this.onPressed,
  });

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  bool _pressed = false;

  bool get _interactive => !widget.loading && widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final child = widget.loading
        ? const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppColors.highlightText,
            ),
          )
        : Text(
            widget.label,
            style: const TextStyle(
              color: AppColors.highlightText,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          );

    return Semantics(
      button: true,
      enabled: _interactive,
      label: widget.label,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: _interactive ? 1.0 : 0.5,
          duration: const Duration(milliseconds: 180),
          child: Material(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: _interactive ? widget.onPressed : null,
              onTapDown: (_) {
                if (_interactive) setState(() => _pressed = true);
              },
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                height: 56,
                alignment: Alignment.center,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}