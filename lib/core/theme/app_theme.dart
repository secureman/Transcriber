import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// ElevenReader-inspired design tokens.
class AppColors {
  static const background = Color(0xFF0D0D0D);
  static const surface = Color(0xFF1A1A1A);
  static const surfaceElevated = Color(0xFF242424);
  static const primary = Color(0xFFF5A623);
  static const textPrimary = Color(0xFFF0F0F0);
  static const textSecondary = Color(0xFF888888);
  static const highlightBg = Color(0xFFF5A623);
  static const highlightText = Color(0xFF0D0D0D);
  static const success = Color(0xFF4CAF50);
  static const error = Color(0xFFE53935);
  static const warning = Color(0xFFFFC107);

  static const double pastWordOpacity = 0.4;
  static const double cardRadius = 12;
  static const double buttonRadius = 24;
  static const double readingFontSize = 22;
}

class AppTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.primary,
        secondary: AppColors.primary,
        surface: AppColors.surface,
        error: AppColors.error,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 4,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintStyle: const TextStyle(color: AppColors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
          borderSide: const BorderSide(color: AppColors.surfaceElevated),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
          borderSide: const BorderSide(color: AppColors.surfaceElevated),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.highlightText,
          textStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppColors.buttonRadius),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surfaceElevated,
        contentTextStyle: GoogleFonts.inter(color: AppColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppColors.cardRadius),
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 2,
        thumbColor: AppColors.primary,
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: AppColors.surfaceElevated,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
      ),
      dividerColor: AppColors.surfaceElevated,
      iconTheme: const IconThemeData(color: AppColors.textPrimary),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).copyWith(
        titleLarge: GoogleFonts.inter(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: GoogleFonts.inter(color: AppColors.textPrimary),
        bodyMedium: GoogleFonts.inter(color: AppColors.textPrimary),
      ),
    );
  }

  /// Reading font (Lora serif) at a given size.
  static TextStyle readingStyle({
    double size = AppColors.readingFontSize,
    bool bold = false,
  }) =>
      GoogleFonts.lora(
        fontSize: size,
        height: 1.9,
        color: AppColors.textPrimary,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      );
}

// ── Reader Themes ─────────────────────────────────────────────────────────

enum ReaderThemeType { dusk, midnight, parchment, snow, forest }

@immutable
class ReaderThemeData {
  const ReaderThemeData({
    required this.name,
    required this.background,
    required this.surface,
    required this.text,
    required this.dimOpacity,
    required this.highlightBg,
    required this.highlightText,
    required this.isDark,
    required this.swatch,
  });

  final String name;
  final Color background;
  final Color surface;
  final Color text;
  final double dimOpacity; // applied to past words
  final Color highlightBg;
  final Color highlightText;
  final bool isDark;
  final Color swatch; // preview circle in the picker

  static const Map<ReaderThemeType, ReaderThemeData> all = {
    ReaderThemeType.dusk: ReaderThemeData(
      name: 'Dusk',
      background: Color(0xFF1C1C1E),
      surface: Color(0xFF28282A),
      text: Color(0xFFEEEEEE),
      dimOpacity: 0.28,
      highlightBg: Color(0xFFF5A623),
      highlightText: Color(0xFF0D0D0D),
      isDark: true,
      swatch: Color(0xFF1C1C1E),
    ),
    ReaderThemeType.midnight: ReaderThemeData(
      name: 'Midnight',
      background: Color(0xFF000000),
      surface: Color(0xFF141414),
      text: Color(0xFFFFFFFF),
      dimOpacity: 0.28,
      highlightBg: Color(0xFFF5A623),
      highlightText: Color(0xFF000000),
      isDark: true,
      swatch: Color(0xFF000000),
    ),
    ReaderThemeType.parchment: ReaderThemeData(
      name: 'Parchment',
      background: Color(0xFFF4ECD8),
      surface: Color(0xFFEDE0C4),
      text: Color(0xFF3D2B1F),
      dimOpacity: 0.30,
      highlightBg: Color(0xFFC47A2B),
      highlightText: Color(0xFFFFFFFF),
      isDark: false,
      swatch: Color(0xFFF4ECD8),
    ),
    ReaderThemeType.snow: ReaderThemeData(
      name: 'Snow',
      background: Color(0xFFF8F8F8),
      surface: Color(0xFFEBEBEB),
      text: Color(0xFF1A1A1A),
      dimOpacity: 0.28,
      highlightBg: Color(0xFFF5A623),
      highlightText: Color(0xFF0D0D0D),
      isDark: false,
      swatch: Color(0xFFF8F8F8),
    ),
    ReaderThemeType.forest: ReaderThemeData(
      name: 'Forest',
      background: Color(0xFF1B2B22),
      surface: Color(0xFF263830),
      text: Color(0xFFC8E6C9),
      dimOpacity: 0.28,
      highlightBg: Color(0xFF66BB6A),
      highlightText: Color(0xFF0D0D0D),
      isDark: true,
      swatch: Color(0xFF1B2B22),
    ),
  };
}
