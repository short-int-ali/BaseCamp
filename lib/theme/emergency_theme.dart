import 'package:flutter/material.dart';

/// High-contrast color palette and widget defaults for Base Camp.
///
/// The palette is deliberately limited to four surface colors, one
/// emergency-red accent, one warning-yellow, and one triage-green.
/// The goal is that every actionable element on screen is either red
/// or high-contrast white-on-near-black, so a responder can read the
/// UI in bright daylight, in rain, through gloves.
class EmergencyPalette {
  EmergencyPalette._();

  /// Base background. Near-black rather than pure black keeps OLED
  /// smearing to a minimum without losing contrast.
  static const Color background = Color(0xFF0A0A0A);

  /// Elevated surfaces (cards, sheets).
  static const Color surface = Color(0xFF151515);

  /// Subtle dividers, disabled states.
  static const Color outline = Color(0xFF2A2A2A);

  /// Primary text on [background] / [surface]. Full-white for max
  /// contrast; large-scale AAA against background.
  static const Color onSurface = Color(0xFFFFFFFF);

  /// Secondary text (disclaimers, hints). Still passes WCAG AA at
  /// body sizes.
  static const Color onSurfaceMuted = Color(0xFFBDBDBD);

  /// The Emergency Red used on the shutter, tier chips for RED, and
  /// selected mode buttons. Picked for visibility, not branding.
  static const Color emergencyRed = Color(0xFFD62828);

  /// Slightly darker red for pressed / active states.
  static const Color emergencyRedDeep = Color(0xFF9E1C1C);

  /// Triage yellow.
  static const Color triageYellow = Color(0xFFF2B705);

  /// Triage green.
  static const Color triageGreen = Color(0xFF2BAE66);
}

class EmergencyTheme {
  EmergencyTheme._();

  /// The single theme used by the app. Dark-mode only by design —
  /// light mode would wash out the camera preview and hurt night-use.
  static ThemeData build() {
    const colorScheme = ColorScheme.dark(
      primary: EmergencyPalette.emergencyRed,
      onPrimary: EmergencyPalette.onSurface,
      secondary: EmergencyPalette.triageYellow,
      onSecondary: EmergencyPalette.background,
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
            // Bump readable body sizes; responders may be at arm's length.
            bodyLarge: base.textTheme.bodyLarge?.copyWith(
              fontSize: 17,
              height: 1.35,
            ),
            labelLarge: base.textTheme.labelLarge?.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: EmergencyPalette.background,
        foregroundColor: EmergencyPalette.onSurface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: EmergencyPalette.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: EmergencyPalette.surface,
        modalBackgroundColor: EmergencyPalette.surface,
        showDragHandle: true,
        dragHandleColor: EmergencyPalette.outline,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(88, 56),
          backgroundColor: EmergencyPalette.emergencyRed,
          foregroundColor: EmergencyPalette.onSurface,
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(88, 56),
          foregroundColor: EmergencyPalette.onSurface,
          side: const BorderSide(
            color: EmergencyPalette.outline,
            width: 1.5,
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
      ),
      iconTheme: const IconThemeData(
        color: EmergencyPalette.onSurface,
        size: 28,
      ),
      dividerTheme: const DividerThemeData(
        color: EmergencyPalette.outline,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
