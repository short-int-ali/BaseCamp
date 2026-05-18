import 'package:flutter/material.dart';

/// High-contrast color palette and widget defaults for Base Camp.
class EmergencyPalette {
  EmergencyPalette._();

  static const Color background = Color(0xFF0B0D10);
  static const Color surface = Color(0xFF161A21);
  static const Color surfaceElevated = Color(0xFF1E232C);
  static const Color outline = Color(0xFF2E3644);
  static const Color outlineSubtle = Color(0xFF242B36);
  static const Color onSurface = Color(0xFFF4F6F8);
  static const Color onSurfaceMuted = Color(0xFF9AA3B2);
  static const Color emergencyRed = Color(0xFFE53935);
  static const Color emergencyRedDeep = Color(0xFFB71C1C);
  static const Color emergencyRedGlow = Color(0x40E53935);
  static const Color triageYellow = Color(0xFFFFB020);
  static const Color triageGreen = Color(0xFF34C759);
  static const Color accentBlue = Color(0xFF5B9CF5);

  static const double radiusSm = 10;
  static const double radiusMd = 14;
  static const double radiusLg = 20;
  static const double radiusXl = 24;
}

class EmergencyTheme {
  EmergencyTheme._();

  static ThemeData build() {
    const colorScheme = ColorScheme.dark(
      primary: EmergencyPalette.emergencyRed,
      onPrimary: EmergencyPalette.onSurface,
      secondary: EmergencyPalette.triageYellow,
      onSecondary: EmergencyPalette.background,
      tertiary: EmergencyPalette.triageGreen,
      error: EmergencyPalette.emergencyRed,
      onError: EmergencyPalette.onSurface,
      surface: EmergencyPalette.surface,
      onSurface: EmergencyPalette.onSurface,
      outline: EmergencyPalette.outline,
    );

    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: EmergencyPalette.background,
      canvasColor: EmergencyPalette.background,
      splashFactory: InkSparkle.splashFactory,
    );

    return base.copyWith(
      textTheme: base.textTheme
          .apply(
            bodyColor: EmergencyPalette.onSurface,
            displayColor: EmergencyPalette.onSurface,
          )
          .copyWith(
            headlineSmall: base.textTheme.headlineSmall?.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
            titleMedium: base.textTheme.titleMedium?.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            bodyLarge: base.textTheme.bodyLarge?.copyWith(
              fontSize: 16,
              height: 1.45,
            ),
            bodyMedium: base.textTheme.bodyMedium?.copyWith(
              fontSize: 14,
              height: 1.4,
              color: EmergencyPalette.onSurfaceMuted,
            ),
            labelLarge: base.textTheme.labelLarge?.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
            labelSmall: base.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: EmergencyPalette.onSurfaceMuted,
            ),
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: EmergencyPalette.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 20,
        titleTextStyle: TextStyle(
          color: EmergencyPalette.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: EmergencyPalette.surface,
        indicatorColor: EmergencyPalette.emergencyRed.withValues(alpha: 0.22),
        elevation: 0,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: 0.4,
            color: selected
                ? EmergencyPalette.emergencyRed
                : EmergencyPalette.onSurfaceMuted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected
                ? EmergencyPalette.emergencyRed
                : EmergencyPalette.onSurfaceMuted,
          );
        }),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: EmergencyPalette.surfaceElevated,
        modalBackgroundColor: EmergencyPalette.surfaceElevated,
        showDragHandle: true,
        dragHandleColor: EmergencyPalette.outline,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(EmergencyPalette.radiusXl),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: EmergencyPalette.surfaceElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EmergencyPalette.radiusMd),
          side: const BorderSide(color: EmergencyPalette.outlineSubtle),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: EmergencyPalette.surface,
        selectedColor: EmergencyPalette.emergencyRed.withValues(alpha: 0.25),
        disabledColor: EmergencyPalette.surface,
        labelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: EmergencyPalette.onSurface,
        ),
        secondaryLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EmergencyPalette.radiusSm),
          side: const BorderSide(color: EmergencyPalette.outline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: EmergencyPalette.background,
        hintStyle: const TextStyle(color: EmergencyPalette.onSurfaceMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(EmergencyPalette.radiusSm),
          borderSide: const BorderSide(color: EmergencyPalette.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(EmergencyPalette.radiusSm),
          borderSide: const BorderSide(color: EmergencyPalette.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(EmergencyPalette.radiusSm),
          borderSide: const BorderSide(
            color: EmergencyPalette.emergencyRed,
            width: 1.5,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: EmergencyPalette.emergencyRed,
        inactiveTrackColor: EmergencyPalette.outline,
        thumbColor: EmergencyPalette.emergencyRed,
        overlayColor: EmergencyPalette.emergencyRedGlow,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: EmergencyPalette.surfaceElevated,
        contentTextStyle: const TextStyle(color: EmergencyPalette.onSurface),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(EmergencyPalette.radiusSm),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(88, 52),
          backgroundColor: EmergencyPalette.emergencyRed,
          foregroundColor: EmergencyPalette.onSurface,
          elevation: 0,
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EmergencyPalette.radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(88, 52),
          foregroundColor: EmergencyPalette.onSurface,
          side: const BorderSide(color: EmergencyPalette.outline, width: 1),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EmergencyPalette.radiusMd),
          ),
        ),
      ),
      iconTheme: const IconThemeData(
        color: EmergencyPalette.onSurface,
        size: 24,
      ),
      dividerTheme: const DividerThemeData(
        color: EmergencyPalette.outlineSubtle,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
