/// Three-tier emergency triage classification.
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

/// A single RAG grounding reference attached to a conversation turn.
///
/// [sourceId] is a stable id (often `dataset_entry_id`). [snippet] is
/// the short excerpt that justifies the claim. [datasetName] and
/// [entryTitle] are shown in the UI so responders see **which dataset
/// and section** the match came from — not just an opaque id.
class KbCitation {
  const KbCitation({
    required this.sourceId,
    required this.snippet,
    this.datasetName,
    this.entryTitle,
  });

  final String sourceId;

  /// Verbatim or lightly trimmed excerpt from the local KB entry.
  final String snippet;

  /// Human-readable dataset label from JSON (e.g. "First-aid protocols").
  final String? datasetName;

  /// Section / entry title within the dataset, when applicable.
  final String? entryTitle;

  /// Compact provenance line for list UIs.
  String get provenanceLine {
    final parts = <String>[
      if (datasetName != null && datasetName!.trim().isNotEmpty)
        datasetName!.trim(),
      if (entryTitle != null && entryTitle!.trim().isNotEmpty)
        entryTitle!.trim(),
      sourceId,
    ];
    return parts.join(' · ');
  }
}
