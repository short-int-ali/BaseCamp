import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../database/medical_kb.dart';
import 'prompts.dart';
import 'vision_mode.dart';
import 'vision_result.dart';

/// Default on-disk location the app expects the LiteRT-LM bundle at,
/// relative to the Flutter asset bundle.
const String kDefaultModelAssetPath =
    'assets/models/gemma4_e4b_int4.litertlm';

/// Long edge (in pixels) frames are resized to before being passed to
/// the Gemma vision encoder. Matches the MobileNet v5 default input
/// used by Gemma's vision tower.
const int kVisionLongEdgePx = 768;

/// Thrown when [VisionProcessor.initialize] cannot locate the model
/// bundle. The UI catches this to render the first-boot gate.
class ModelMissingException implements Exception {
  ModelMissingException(this.expectedPath);
  final String expectedPath;

  @override
  String toString() =>
      'ModelMissingException: LiteRT-LM bundle not found at $expectedPath';
}

/// Thin seam over [LiteLmEngine] so tests can stub inference without
/// spinning up the native runtime. Production wiring uses
/// [_RealLiteRtEngine] which delegates straight to the plugin.
abstract class LiteRtEngine {
  Future<String> generateJson({
    required String systemInstruction,
    required String userText,
    required Uint8List imageBytes,
  });

  Future<void> dispose();
}

class _RealLiteRtEngine implements LiteRtEngine {
  _RealLiteRtEngine(this._engine);

  final LiteLmEngine _engine;

  @override
  Future<String> generateJson({
    required String systemInstruction,
    required String userText,
    required Uint8List imageBytes,
  }) async {
    // One-shot conversation per call. Keeping conversations short-lived
    // avoids state leaking across modes (Pills prompt contaminating
    // Patients, etc.) and releases native memory promptly.
    final conversation = await _engine.createConversation(
      LiteLmConversationConfig(
        systemInstruction: systemInstruction,
        samplerConfig: const LiteLmSamplerConfig(
          temperature: 0.2,
          topK: 40,
          topP: 0.95,
        ),
      ),
    );
    try {
      final reply = await conversation.sendMultimodalMessage([
        LiteLmContent.text(userText),
        LiteLmContent.imageBytes(imageBytes),
      ]);
      return reply.text;
    } finally {
      await conversation.dispose();
    }
  }

  @override
  Future<void> dispose() => _engine.dispose();
}

/// Single-engine lifecycle wrapper around LiteRT-LM with mode-dispatched
/// prompting and RAG grounding.
///
/// Typical usage:
///
/// ```dart
/// final processor = VisionProcessor(kb: const NoopMedicalKb());
/// await processor.initialize();
/// final result = await processor.analyze(
///   jpegBytes: bytes,
///   mode: VisionMode.patients,
/// );
/// // ... render result ...
/// await processor.dispose();
/// ```
class VisionProcessor {
  VisionProcessor({
    required MedicalKb kb,
    @visibleForTesting LiteRtEngine? engineOverride,
  })  : _kb = kb,
        _engineOverride = engineOverride;

  final MedicalKb _kb;
  final LiteRtEngine? _engineOverride;

  LiteRtEngine? _engine;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// Copy the model bundle out of the asset bundle (if needed) and
  /// bring up the LiteRT-LM engine.
  ///
  /// Throws [ModelMissingException] if the bundle is missing. The UI
  /// is expected to catch that and render the first-boot gate.
  Future<void> initialize({
    String modelAssetPath = kDefaultModelAssetPath,
  }) async {
    if (_initialized) return;

    if (_engineOverride != null) {
      _engine = _engineOverride;
      _initialized = true;
      return;
    }

    final modelPath = await _ensureModelOnDisk(modelAssetPath);

    final backend = _pickBackend();
    final engine = await LiteLmEngine.create(
      LiteLmEngineConfig(
        modelPath: modelPath,
        backend: backend,
      ),
    );
    _engine = _RealLiteRtEngine(engine);
    _initialized = true;
  }

  /// Capture one frame, run the mode-specific prompt, cross-reference
  /// the medical KB, and return a [VisionResult].
  Future<VisionResult> analyze({
    required Uint8List jpegBytes,
    required VisionMode mode,
  }) async {
    final engine = _engine;
    if (!_initialized || engine == null) {
      throw StateError(
        'VisionProcessor.analyze called before initialize()',
      );
    }

    final preprocessed = _preprocess(jpegBytes);
    final systemInstruction = VisionPrompts.forMode(mode);

    final rawJson = await engine.generateJson(
      systemInstruction: systemInstruction,
      userText: 'Analyze the attached image according to MODE rules.',
      imageBytes: preprocessed,
    );
    final parsed = _tolerantJsonParse(rawJson);

    switch (mode) {
      case VisionMode.pills:
        return _buildPillsResult(parsed);
      case VisionMode.plants:
        return _buildPlantsResult(parsed);
      case VisionMode.patients:
        return _buildPatientsResult(parsed);
    }
  }

  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
    _initialized = false;
  }

  // ------------------------------------------------------------------
  // Model asset management
  // ------------------------------------------------------------------

  /// Resolve the on-disk absolute path the LiteRT-LM engine expects.
  ///
  /// Strategy:
  ///   1. If a copy already exists in app-support, use it.
  ///   2. Else, try to read the model out of the Flutter asset bundle
  ///      and copy it over.
  ///   3. If neither is possible, throw [ModelMissingException].
  Future<String> _ensureModelOnDisk(String assetPath) async {
    final appDir = await getApplicationSupportDirectory();
    final filename = assetPath.split('/').last;
    final destination = File('${appDir.path}/$filename');

    if (await destination.exists() && await destination.length() > 0) {
      return destination.path;
    }

    try {
      final bytes = await rootBundle.load(assetPath);
      await destination.writeAsBytes(
        bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        ),
        flush: true,
      );
      return destination.path;
    } catch (_) {
      throw ModelMissingException(assetPath);
    }
  }

  LiteLmBackend _pickBackend() {
    // iOS only supports CPU today (Metal accelerator isn't shipped
    // upstream). On Android prefer GPU; real devices have OpenCL,
    // emulators don't — the engine will surface an error there and
    // callers can retry with CPU.
    if (Platform.isIOS) return LiteLmBackend.cpu;
    return LiteLmBackend.gpu;
  }

  // ------------------------------------------------------------------
  // Image preprocessing
  // ------------------------------------------------------------------

  /// Resize the captured JPEG to a bounded long edge and re-encode.
  ///
  /// Keeps vision-encoder memory predictable and strips EXIF that
  /// could otherwise confuse orientation on some devices.
  Uint8List _preprocess(Uint8List jpegBytes) {
    final decoded = img.decodeJpg(jpegBytes);
    if (decoded == null) {
      // Fall back to the raw bytes rather than failing the whole
      // analysis — the model can sometimes still extract signal.
      return jpegBytes;
    }
    final longEdge = decoded.width > decoded.height
        ? decoded.width
        : decoded.height;
    if (longEdge <= kVisionLongEdgePx) {
      return Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
    }
    final scale = kVisionLongEdgePx / longEdge;
    final resized = img.copyResize(
      decoded,
      width: (decoded.width * scale).round(),
      height: (decoded.height * scale).round(),
      interpolation: img.Interpolation.average,
    );
    return Uint8List.fromList(img.encodeJpg(resized, quality: 90));
  }

  // ------------------------------------------------------------------
  // Model output parsing
  // ------------------------------------------------------------------

  /// Parse JSON produced by the model, tolerating common deviations
  /// (markdown code fences, leading prose).
  Map<String, dynamic> _tolerantJsonParse(String raw) {
    var text = raw.trim();

    // Strip ```json ... ``` or ``` ... ``` fences.
    if (text.startsWith('```')) {
      final firstNewline = text.indexOf('\n');
      if (firstNewline != -1) {
        text = text.substring(firstNewline + 1);
      }
      final closingFence = text.lastIndexOf('```');
      if (closingFence != -1) {
        text = text.substring(0, closingFence);
      }
      text = text.trim();
    }

    // Isolate the first {...} block if prose leaked in.
    final firstBrace = text.indexOf('{');
    final lastBrace = text.lastIndexOf('}');
    if (firstBrace != -1 && lastBrace > firstBrace) {
      text = text.substring(firstBrace, lastBrace + 1);
    }

    try {
      final decoded = json.decode(text);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // fall through
    }
    return const <String, dynamic>{};
  }

  // ------------------------------------------------------------------
  // Mode-specific post-processing
  // ------------------------------------------------------------------

  Future<VisionResult> _buildPillsResult(Map<String, dynamic> parsed) async {
    final imprint = (parsed['imprint'] as String? ?? '').trim();
    final shape = (parsed['shape'] as String? ?? 'unknown').trim();
    final color = (parsed['color'] as String? ?? 'unknown').trim();
    final modelSummary =
        (parsed['summary'] as String? ?? 'No description available.').trim();
    final warnings = _stringList(parsed['warnings']);

    final matches = await _kb.lookupPillImprint(
      imprint: imprint,
      shape: shape,
      color: color,
    );

    String summary;
    List<KbCitation> citations;
    bool grounded;
    if (matches.isEmpty) {
      summary =
          '$modelSummary No match found in the local pill database — '
          'do not rely on this description to identify the medication.';
      citations = const [];
      grounded = false;
      warnings.add('Pill not verified against local KB.');
    } else {
      final best = matches.first;
      summary = '${best.name} ${best.strength}. ${best.notes}'.trim();
      citations = [best.citation];
      grounded = true;
    }

    return VisionResult(
      mode: VisionMode.pills,
      summary: _withDisclaimer(summary),
      warnings: warnings,
      citations: citations,
      groundedByRag: grounded,
      disclaimer: kNonDiagnosticDisclaimer,
    );
  }

  Future<VisionResult> _buildPlantsResult(Map<String, dynamic> parsed) async {
    final likelySpecies =
        (parsed['likely_species'] as String? ?? '').trim();
    final cues = _stringList(parsed['toxicity_cues']);
    final modelRisk =
        (parsed['risk'] as String? ?? 'unknown').trim().toLowerCase();
    final modelSummary =
        (parsed['summary'] as String? ?? 'No description available.').trim();
    final warnings = _stringList(parsed['warnings']);

    final toxicity = await _kb.lookupPlantToxicity(
      likelySpecies: likelySpecies.isEmpty ? null : likelySpecies,
      cues: cues,
    );

    String summary = modelSummary;
    List<KbCitation> citations = const [];
    bool grounded = false;

    if (toxicity.isNotEmpty) {
      final top = toxicity.first;
      summary = '${top.commonName}: ${top.notes}';
      citations = [top.citation];
      grounded = true;
      if (top.risk == 'high') {
        warnings.insert(0, 'HIGH TOXICITY — do not touch or ingest.');
      } else if (top.risk == 'moderate') {
        warnings.insert(0, 'Moderate toxicity — avoid skin contact.');
      }
    } else {
      if (modelRisk == 'high') {
        warnings.insert(
          0,
          'Model reports high toxicity but no KB match — treat as unknown dangerous plant.',
        );
      }
      warnings.add('Plant not verified against local KB.');
    }

    return VisionResult(
      mode: VisionMode.plants,
      summary: _withDisclaimer(summary),
      warnings: warnings,
      citations: citations,
      groundedByRag: grounded,
      disclaimer: kNonDiagnosticDisclaimer,
    );
  }

  Future<VisionResult> _buildPatientsResult(
    Map<String, dynamic> parsed,
  ) async {
    final observedSigns = _stringList(parsed['observed_signs']);
    final visibleBleeding = parsed['visible_bleeding'] == true;
    final responsiveAppearing = parsed['responsive_appearing'] as bool?;
    final modelSummary =
        (parsed['summary'] as String? ?? 'No description available.').trim();
    final warnings = _stringList(parsed['warnings']);

    final rule = await _kb.lookupTriageRule(
      observedSigns: observedSigns,
      visibleBleeding: visibleBleeding,
      responsiveAppearing: responsiveAppearing,
    );

    TriageTier tier;
    List<KbCitation> citations;
    bool grounded;
    String summary;

    if (rule != null) {
      tier = rule.tier;
      citations = [rule.citation];
      grounded = true;
      summary = '${modelSummary} Triage: ${tier.label}. ${rule.rationale}';
    } else {
      // Downgrade-to-yellow hallucination guard: without KB citation
      // we refuse to assign RED and ask the responder to verify.
      tier = TriageTier.yellow;
      citations = const [];
      grounded = false;
      summary =
          '$modelSummary No local protocol match — defaulting to YELLOW. '
          'Verify against local triage protocol before acting.';
      warnings.add('Triage tier not verified against local KB.');
    }

    return VisionResult(
      mode: VisionMode.patients,
      summary: _withDisclaimer(summary),
      warnings: warnings,
      citations: citations,
      groundedByRag: grounded,
      disclaimer: kNonDiagnosticDisclaimer,
      triage: tier,
    );
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  List<String> _stringList(dynamic v) {
    if (v is List) {
      return v
          .map((e) => e?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return <String>[];
  }

  String _withDisclaimer(String summary) {
    final clean = summary.trim();
    if (clean.isEmpty) return kNonDiagnosticDisclaimer;
    return '$clean\n\n$kNonDiagnosticDisclaimer';
  }
}
