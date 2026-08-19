import 'package:flutter/material.dart';

class AppColors {
  static const seed = Color(0xFF2E9E46);
  static const primary = Color(0xFF1B7A34);
  static const primaryDark = Color(0xFF0F5A24);
  static const accent = Color(0xFF8BC53F);
  static const accentLight = Color(0xFFB8E986);
  static const surface = Color(0xFFF7FBF7);

  static const gradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [accentLight, primary],
  );
}

ThemeData buildAppTheme() {
  final base = ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    primary: AppColors.primary,
    secondary: AppColors.accent,
    surface: AppColors.surface,
    brightness: Brightness.light,
  );

  return ThemeData(
    colorScheme: base,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.surface,
    appBarTheme: AppBarTheme(
      scrolledUnderElevation: 0,
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.primaryDark,
      titleTextStyle: const TextStyle(
        color: AppColors.primaryDark,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
    ),
    chipTheme: ChipThemeData(
      selectedColor: AppColors.accent.withValues(alpha: 0.35),
      checkmarkColor: AppColors.primaryDark,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.primary,
    ),
  );
}
