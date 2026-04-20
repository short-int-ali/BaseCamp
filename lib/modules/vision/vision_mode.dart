/// Snap-and-Solve capture modes.
///
/// The three values correspond to the three shutter-bar buttons in
/// [EmergencyUI] and drive prompt selection and post-processing inside
/// [VisionProcessor].
enum VisionMode {
  /// OCR pill imprints and cross-reference the medical KB.
  pills,

  /// Identify toxic plant characteristics and raise safety warnings.
  plants,

  /// Analyze wound / pallor / posture and produce a Red/Yellow/Green
  /// triage tier gated by RAG citations.
  patients,
}

extension VisionModeX on VisionMode {
  /// Short, human-readable label used on mode buttons.
  String get label {
    switch (this) {
      case VisionMode.pills:
        return 'PILLS';
      case VisionMode.plants:
        return 'PLANTS';
      case VisionMode.patients:
        return 'PATIENTS';
    }
  }
}
