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

/// A first-aid / clinical protocol snippet returned by
/// [MedicalKb.searchProtocols]. Used by the audio gateway to ground
/// spoken answers against the local KB and to surface citations in
/// the transcript — same pattern as the vision module.
class ProtocolHit {
  const ProtocolHit({
    required this.title,
    required this.snippet,
    required this.citation,
    this.score = 0.0,
  });

  /// Short human-readable title, e.g. `"Severe bleeding control"`.
  final String title;

  /// 1-3 sentence excerpt of the protocol text that will be shown to
  /// the user and/or fed back into the model for a grounded answer.
  final String snippet;

  /// Retrieval score in [0, 1]. Higher is more relevant. Callers may
  /// filter on this before grounding (e.g. ignore < 0.2).
  final double score;

  final KbCitation citation;
}

/// Local, offline medical knowledge base. Used by [AudioGateway] to
/// ground model output and by the (future) multilingual module to
/// verify medical terminology before it is spoken aloud.
///
/// Implementations MUST NOT perform any network IO.
abstract class MedicalKb {
  /// Hint that a Gemma / LiteRT multimodal turn is in flight.
  ///
  /// Implementations can defer heavy native work (e.g. vector-index
  /// builds) while this is true. Default is a no-op.
  void setLiteRtInferenceActive(bool active) {}

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

  /// Free-text search over first-aid / clinical protocols in the local
  /// KB. Used by the hands-free audio gateway to ground model output
  /// against verified protocol text and surface KB citations. Returns
  /// an empty list if nothing relevant is found.
  Future<List<ProtocolHit>> searchProtocols(String query);
}

/// Placeholder implementation used until a real vector store ships.
///
/// Every method returns an empty / null result. [AudioGateway] is
/// written to handle this gracefully: Pills mode reports "not matched
/// in local KB", Patients mode falls back to YELLOW with a verify
/// warning, and Plants mode surfaces the model's own cues without
/// adding KB-sourced context.
class NoopMedicalKb implements MedicalKb {
  const NoopMedicalKb();

  @override
  void setLiteRtInferenceActive(bool active) {}

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

  @override
  Future<List<ProtocolHit>> searchProtocols(String query) async => const [];
}
