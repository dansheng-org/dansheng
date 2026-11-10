import 'package:flutter/material.dart';

/// Modern Chinese campus workbench theme with warm offwhite paper and ink/teal editorial identity.
/// Provides high-contrast, large-font accessible typography and unclipped spacious layout.
class AppTheme {
  static const seedColor = Color(0xff145648);
  static final lightTheme = _build(Brightness.light);
  static final darkTheme = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final paper = dark ? const Color(0xff101816) : const Color(0xfff8f7f2);
    final cardBg = dark ? const Color(0xff17221f) : const Color(0xffffffff);
    final border = dark ? const Color(0xff293833) : const Color(0xffe5e1d5);

    final c = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    ).copyWith(
      surface: paper,
      onSurface: dark ? const Color(0xffe4ede8) : const Color(0xff1b2622),
      surfaceContainerLowest: cardBg,
      surfaceContainerLow: dark ? const Color(0xff141e1b) : const Color(0xfff2efe5),
      surfaceContainer: dark ? const Color(0xff1c2724) : const Color(0xffeae6dc),
      surfaceContainerHigh: dark ? const Color(0xff23302c) : const Color(0xffe3ded2),
      primary: dark ? const Color(0xff86d3b8) : const Color(0xff135446),
      onPrimary: dark ? const Color(0xff063428) : Colors.white,
      primaryContainer: dark ? const Color(0xff1b473b) : const Color(0xffd7ede3),
      onPrimaryContainer: dark ? const Color(0xffb8eedb) : const Color(0xff063327),
      secondary: dark ? const Color(0xff9ec7b9) : const Color(0xff326659),
      secondaryContainer: dark ? const Color(0xff233932) : const Color(0xffdbeef5),
      tertiaryContainer: dark ? const Color(0xff3f341f) : const Color(0xfff3ebd7),
      onTertiaryContainer: dark ? const Color(0xfffae5be) : const Color(0xff3d2e14),
      outlineVariant: border,
    );

    final base = ThemeData(
      colorScheme: c,
      brightness: brightness,
      useMaterial3: true,
    );

    return base.copyWith(
      scaffoldBackgroundColor: paper,
      appBarTheme: AppBarTheme(
        backgroundColor: paper,
        foregroundColor: c.onSurface,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          color: c.onSurface,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.8,
          color: c.onSurface,
        ),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: c.onSurface,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: c.onSurface,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          height: 1.45,
        ),
      ),
      cardTheme: CardThemeData(
        color: cardBg,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: border, width: 1.0),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: cardBg,
        indicatorColor: c.secondaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          base.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: paper,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: border),
        ),
        backgroundColor: c.surfaceContainerLow,
        labelStyle: TextStyle(
          color: c.onSurface,
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: c.primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }
}
