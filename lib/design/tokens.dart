import 'package:flutter/material.dart';

abstract final class AppTokens {
  static const pagePadding = 24.0;
  static const contentWidth = 480.0;
  static const sectionGap = 40.0;
  static const controlGap = 12.0;
  static const smallGap = 16.0;
  static const tileRadius = 24.0;

  static const seedColor = Color(0xFFEF716C);
  static const surfaceColor = Color(0xFFF9F9F9);
  static const coral = Color(0xFFEF716C);
  static const ink = Color(0xFF333333);
  static const mutedInk = Color(0xFF8A8A8A);
  static const hairline = Color(0xFFE9E9E9);
  static const tile = Color(0xFFF1F1F1);
  static const lavender = Color(0xFFB9A0FF);
  static const paper = Color(0xFFFFF4E7);

  /// The one accent: a pale red used sparingly (capture, live states).
  static const blush = Color(0xFFF08F89);
  static const blushSoft = Color(0xFFFBE3E1);
  static const barInk = ink;

  /// One colour per collected sound, in capture order.
  static const soundColors = [
    Color(0xFFEF716C),
    Color(0xFF9C84F0),
    Color(0xFFF2A93B),
    Color(0xFF4FAE8C),
    Color(0xFF4E97E0),
    Color(0xFFE071B4),
  ];

  static Color soundColor(int index) =>
      soundColors[index % soundColors.length];
}

ThemeData buildOtogurashiTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppTokens.seedColor,
    brightness: Brightness.light,
    surface: AppTokens.surfaceColor,
  ).copyWith(
    primary: AppTokens.ink,
    onPrimary: Colors.white,
    secondary: AppTokens.blush,
    onSecondary: Colors.white,
    secondaryContainer: AppTokens.blushSoft,
    onSecondaryContainer: AppTokens.ink,
    onSurface: AppTokens.ink,
    outlineVariant: AppTokens.hairline,
  );
  const pill = WidgetStatePropertyAll(StadiumBorder());
  const bold = WidgetStatePropertyAll(
    TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppTokens.surfaceColor,
    cardColor: Colors.white,
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.tileRadius),
      ),
    ),
    chipTheme: const ChipThemeData(
      shape: StadiumBorder(),
      side: BorderSide(color: AppTokens.hairline),
      backgroundColor: Colors.white,
      labelStyle: TextStyle(
        color: AppTokens.ink,
        fontWeight: FontWeight.w700,
      ),
    ),
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        color: AppTokens.ink,
        fontWeight: FontWeight.w800,
        height: 1.18,
        letterSpacing: -0.8,
      ),
      headlineSmall: TextStyle(
        color: AppTokens.ink,
        fontWeight: FontWeight.w800,
        height: 1.2,
      ),
      titleLarge: TextStyle(color: AppTokens.ink, fontWeight: FontWeight.w800),
      titleMedium: TextStyle(
        color: AppTokens.ink,
        fontWeight: FontWeight.w700,
        height: 1.35,
      ),
      bodyLarge: TextStyle(color: AppTokens.ink, height: 1.6),
      bodyMedium: TextStyle(color: AppTokens.ink),
      bodySmall: TextStyle(color: AppTokens.mutedInk, height: 1.5),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppTokens.ink,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: AppTokens.ink,
        fontSize: 17,
        fontWeight: FontWeight.w800,
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: AppTokens.ink,
      unselectedLabelColor: AppTokens.mutedInk,
      indicatorColor: AppTokens.ink,
      dividerColor: AppTokens.hairline,
      labelStyle: TextStyle(fontWeight: FontWeight.w800),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppTokens.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size.fromHeight(56)),
        shape: pill,
        textStyle: bold,
      ),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size.fromHeight(56)),
        shape: pill,
        textStyle: bold,
        foregroundColor: WidgetStatePropertyAll(AppTokens.ink),
        side: WidgetStatePropertyAll(BorderSide(color: AppTokens.hairline)),
      ),
    ),
    textButtonTheme: const TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(AppTokens.ink),
        textStyle: WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    ),
  );
}
