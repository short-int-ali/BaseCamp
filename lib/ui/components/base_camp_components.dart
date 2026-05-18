import 'package:flutter/material.dart';

import '../../modules/vision/vision_result.dart';
import '../../theme/emergency_theme.dart';

/// Pill badge for MODEL / VOICE / LOADING status in app bars.
class BaseCampStatusBadge extends StatelessWidget {
  const BaseCampStatusBadge({
    super.key,
    required this.icon,
    required this.label,
    required this.ready,
  });

  final IconData icon;
  final String label;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final color =
        ready ? EmergencyPalette.triageGreen : EmergencyPalette.onSurfaceMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared non-diagnostic disclaimer footer.
class BaseCampDisclaimerBanner extends StatelessWidget {
  const BaseCampDisclaimerBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            EmergencyPalette.emergencyRedDeep.withValues(alpha: 0.92),
            EmergencyPalette.emergencyRedDeep,
          ],
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: EmergencyPalette.onSurface.withValues(alpha: 0.85),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: EmergencyPalette.onSurface.withValues(alpha: 0.95),
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.35,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Triage tier chip (RED / YELLOW / GREEN).
class BaseCampTriageChip extends StatelessWidget {
  const BaseCampTriageChip({super.key, required this.tier});

  final TriageTier tier;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    switch (tier) {
      case TriageTier.red:
        bg = EmergencyPalette.emergencyRed;
        fg = EmergencyPalette.onSurface;
      case TriageTier.yellow:
        bg = EmergencyPalette.triageYellow;
        fg = EmergencyPalette.background;
      case TriageTier.green:
        bg = EmergencyPalette.triageGreen;
        fg = EmergencyPalette.background;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        tier.label,
        style: TextStyle(
          color: fg,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// KB grounding verification chip.
class BaseCampGroundingChip extends StatelessWidget {
  const BaseCampGroundingChip({super.key, required this.grounded});

  final bool grounded;

  @override
  Widget build(BuildContext context) {
    final color = grounded
        ? EmergencyPalette.triageGreen
        : EmergencyPalette.triageYellow;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            grounded ? Icons.verified_rounded : Icons.help_outline_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            grounded ? 'KB verified' : 'Not verified',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Sheet / section title with optional icon.
class BaseCampSheetHeader extends StatelessWidget {
  const BaseCampSheetHeader({
    super.key,
    required this.title,
    this.icon,
    this.onClose,
  });

  final String title;
  final IconData? icon;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, color: EmergencyPalette.emergencyRed, size: 22),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        if (onClose != null)
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
            style: IconButton.styleFrom(
              backgroundColor: EmergencyPalette.surface,
            ),
          ),
      ],
    );
  }
}

/// Large circular primary action (mic or shutter).
class BaseCampCircularAction extends StatelessWidget {
  const BaseCampCircularAction({
    super.key,
    required this.size,
    required this.color,
    required this.icon,
    required this.busy,
    this.ringColor,
    this.iconColor,
    this.onTap,
    this.semanticsLabel,
  });

  final double size;
  final Color color;
  final IconData icon;
  final bool busy;
  final Color? ringColor;
  final Color? iconColor;
  final VoidCallback? onTap;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final outer = ringColor ?? EmergencyPalette.emergencyRedGlow;
    return Semantics(
      button: true,
      enabled: onTap != null && !busy,
      label: semanticsLabel,
      child: GestureDetector(
        onTap: busy ? null : onTap,
        child: Container(
          width: size + 16,
          height: size + 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: outer,
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(
                color: EmergencyPalette.onSurface.withValues(alpha: 0.9),
                width: 3,
              ),
            ),
            alignment: Alignment.center,
            child: busy
                ? SizedBox(
                    width: size * 0.38,
                    height: size * 0.38,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: iconColor ?? EmergencyPalette.onSurface,
                    ),
                  )
                : Icon(
                    icon,
                    color: iconColor ?? EmergencyPalette.onSurface,
                    size: size * 0.42,
                  ),
          ),
        ),
      ),
    );
  }
}

/// Elevated surface card with optional accent border.
class BaseCampSurfaceCard extends StatelessWidget {
  const BaseCampSurfaceCard({
    super.key,
    required this.child,
    this.accentColor,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget child;
  final Color? accentColor;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: EmergencyPalette.surfaceElevated,
        borderRadius: BorderRadius.circular(EmergencyPalette.radiusMd),
        border: Border.all(
          color: accentColor ?? EmergencyPalette.outlineSubtle,
          width: accentColor != null ? 1.5 : 1,
        ),
      ),
      child: child,
    );
  }
}

/// Warning callout banner.
class BaseCampWarningBanner extends StatelessWidget {
  const BaseCampWarningBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return BaseCampSurfaceCard(
      accentColor: EmergencyPalette.emergencyRed.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: EmergencyPalette.triageYellow,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: EmergencyPalette.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Subtle top accent line for screen headers.
class BaseCampHeaderAccent extends StatelessWidget {
  const BaseCampHeaderAccent({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 3,
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        gradient: LinearGradient(
          colors: [
            EmergencyPalette.emergencyRed.withValues(alpha: 0),
            EmergencyPalette.emergencyRed,
            EmergencyPalette.emergencyRed.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}
