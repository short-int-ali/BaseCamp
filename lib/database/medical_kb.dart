import '../modules/vision/vision_result.dart';

/// A single pill-imprint match returned by [MedicalKb.lookupPillImprint].
///
/// A match is always accompanied by a [KbCitation] so the UI can render
/// the source snippet and the [VisionResult] is honest about what
/// grounded the answer.
class PillMatch {
  const PillMatch({
    required this.name,
    required this.strength,
    required this.notes,
    required this.citation,
  });

  final String name;
  final String strength;
  final String notes;
  final KbCitation citation;
}

/// A plant-toxicity lookup result.
class PlantToxicity {
  const PlantToxicity({
    required this.commonName,
    required this.risk,
    required this.notes,
    required this.citation,
  });

  final String commonName;

  /// One of "low", "moderate", "high".
  final String risk;

  final String notes;
  final KbCitation citation;
}

/// Rule bound to a [TriageTier] with the KB citation that justifies it.
class TriageRule {
  const TriageRule({
    required this.tier,
    required this.rationale,
    required this.citation,
  });

  final TriageTier tier;
  final String rationale;
  final KbCitation citation;
}

/// Local, offline medical knowledge base. Used by [VisionProcessor] to
/// ground model output and by the (future) multilingual module to
/// verify medical terminology before it is spoken aloud.
///
/// Implementations MUST NOT perform any network IO.
abstract class MedicalKb {
  /// Look up a pill by imprint, shape and color. Returns an empty list
  /// if nothing matches.
  Future<List<PillMatch>> lookupPillImprint({
    required String imprint,
    required String shape,
    required String color,
  });

  /// Look up plant-toxicity information. Callers may pass either a
  /// likely species (preferred) or a bag of observed cues.
  Future<List<PlantToxicity>> lookupPlantToxicity({
    String? likelySpecies,
    List<String> cues = const [],
  });

  /// Map a bag of observed patient signs to the most severe applicable
  /// triage rule. Returns null if no rule matches (the caller should
  /// then downgrade to YELLOW and warn "verify with protocol").
  Future<TriageRule?> lookupTriageRule({
    required List<String> observedSigns,
    required bool visibleBleeding,
    required bool? responsiveAppearing,
  });
}

/// Placeholder implementation used until a real vector store ships.
///
/// Every method returns an empty / null result. [VisionProcessor] is
/// written to handle this gracefully: Pills mode reports "not matched
/// in local KB", Patients mode falls back to YELLOW with a verify
/// warning, and Plants mode surfaces the model's own cues without
/// adding KB-sourced context.
class NoopMedicalKb implements MedicalKb {
  const NoopMedicalKb();

  @override
  Future<List<PillMatch>> lookupPillImprint({
    required String imprint,
    required String shape,
    required String color,
  }) async =>
      const [];

  @override
  Future<List<PlantToxicity>> lookupPlantToxicity({
    String? likelySpecies,
    List<String> cues = const [],
  }) async =>
      const [];

  @override
  Future<TriageRule?> lookupTriageRule({
    required List<String> observedSigns,
    required bool visibleBleeding,
    required bool? responsiveAppearing,
  }) async =>
      null;
}
