import 'vision_mode.dart';

/// Three-tier emergency triage classification. Only populated for
/// [VisionMode.patients] results.
enum TriageTier {
  /// Immediate, life-threatening. Intervene now.
  red,

  /// Urgent but not immediately life-threatening.
  yellow,

  /// Non-urgent / walking wounded.
  green,
}

extension TriageTierX on TriageTier {
  String get label {
    switch (this) {
      case TriageTier.red:
        return 'RED';
      case TriageTier.yellow:
        return 'YELLOW';
      case TriageTier.green:
        return 'GREEN';
    }
  }
}

/// A single RAG grounding reference attached to a [VisionResult].
///
/// `sourceId` is whatever opaque identifier the local [MedicalKb]
/// returns (a row id, a document hash, etc.). `snippet` is the short
/// excerpt that justifies the claim and is safe to render verbatim to
/// the responder.
class KbCitation {
  const KbCitation({
    required this.sourceId,
    required this.snippet,
  });

  final String sourceId;
  final String snippet;
}

/// Structured output of a single Snap-and-Solve invocation.
///
/// Every field except [triage] is populated for all modes. [triage] is
/// only non-null when [mode] is [VisionMode.patients].
class VisionResult {
  const VisionResult({
    required this.mode,
    required this.summary,
    required this.warnings,
    required this.citations,
    required this.groundedByRag,
    required this.disclaimer,
    this.triage,
  });

  final VisionMode mode;

  /// One-to-three sentence responder-facing summary. Always ends with
  /// the non-diagnostic disclaimer (see [disclaimer]).
  final String summary;

  /// High-signal safety headlines surfaced above the summary in the UI
  /// (e.g. "Contains cardiac glycosides — do not induce vomiting").
  final List<String> warnings;

  /// Local-KB citations backing any medical claim in [summary].
  final List<KbCitation> citations;

  /// True iff [summary]'s medical assertions were cross-referenced
  /// against [MedicalKb]. A false value means the model produced a
  /// description but the UI must show a "not verified" affordance.
  final bool groundedByRag;

  /// Persistent non-diagnostic disclaimer. Repeated here so headless
  /// consumers of the result (e.g. logging) carry it too.
  final String disclaimer;

  /// Only set when [mode] == [VisionMode.patients].
  final TriageTier? triage;
}
