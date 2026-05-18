import 'dart:convert';
import 'dart:math' show sqrt;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../modules/vision/vision_result.dart';
import 'medical_kb.dart';

/// Loads offline datasets from `assets/kb/datasets/` and implements
/// [MedicalKb]. First-aid protocol retrieval uses an in-memory 1024-D
/// feature-hash vector index (pure Dart — no FFmpeg / ObjectBox native
/// plugins). Triage rules use a structured JSON lookup.
///
/// Two protocol sources are merged at load time:
///
/// * `protocols.json` — small handcrafted starter entries.
/// * `firstaid_rag_chunks.jsonl` — large chunked corpus (each line is a
///   `{id, source, section, pages, text}` record). When present, it is
///   appended to the in-memory index and each chunk carries its own
///   `source` as the dataset label, so citations surface the real
///   reference (e.g. "Canadian Red Cross Guide · Check, Call, Care
///   (pp. 31–32) · firstaid_0019") instead of a generic heading.
///
class FileMedicalKb implements MedicalKb {
  FileMedicalKb._({
    required this.triageDatasetName,
    required List<_ProtocolDoc> protocols,
    required List<_TriageRow> triage,
    required Map<String, _ProtocolDoc> protocolById,
  })  : _protocols = protocols,
        _protocolById = protocolById,
        _triage = triage;

  final String triageDatasetName;

  final List<_ProtocolDoc> _protocols;
  final Map<String, _ProtocolDoc> _protocolById;
  bool _vectorIndexReady = false;
  Future<bool>? _vectorIndexFuture;
  List<_VectorChunk> _vectorIndex = const [];
  bool _liteRtInferenceActive = false;
  final List<_TriageRow> _triage;

  /// Load all bundled datasets. Uses [rootBundle] when [bundle] is omitted.
  static Future<FileMedicalKb> load([AssetBundle? bundle]) async {
    final b = bundle ?? rootBundle;

    final triageJson = await b.loadString('assets/kb/datasets/triage.json');
    final triageRoot = jsonDecode(triageJson) as Map<String, dynamic>;

    final triageName =
        (triageRoot['dataset_name'] as String? ?? 'Triage').trim();

    final protocols = <_ProtocolDoc>[];
    await _appendProtocolsFromStarter(b, protocols);
    await _appendProtocolsFromJsonl(
      b,
      'assets/kb/datasets/firstaid_rag_chunks.jsonl',
      protocols,
    );

    final triage = (triageRoot['entries'] as List<dynamic>? ?? [])
        .map((e) => _TriageRow.fromJson(e as Map<String, dynamic>))
        .where((e) => e.id.isNotEmpty && e.signTerms.isNotEmpty)
        .toList();

    final protocolById = <String, _ProtocolDoc>{};
    for (final p in protocols) {
      protocolById[p.id] = p;
    }

    final storableProtocols = protocols
        .where((p) => '${p.title}\n\n${p.body}'.trim().isNotEmpty)
        .toList();
    return FileMedicalKb._(
      triageDatasetName: triageName,
      protocols: protocols,
      triage: triage,
      protocolById: protocolById,
    ).._vectorIndexReady = storableProtocols.isEmpty;
  }

  @override
  void setLiteRtInferenceActive(bool active) {
    _liteRtInferenceActive = active;
  }

  /// Start building the in-memory protocol vector index in the background.
  ///
  /// Prefer [scheduleProtocolIndexWarmAfterFirstAudioTurn] from the audio
  /// gateway so embedding work does not run during the first multimodal
  /// mic turn (common INTERNAL / native crash window).
  void warmProtocolIndexInBackground() {
    if (_vectorIndexReady || _vectorIndexFuture != null) return;
    if (_liteRtInferenceActive) return;
    _vectorIndexFuture = _buildVectorIndex();
  }

  /// Defer vector indexing until after the first successful ASK inference.
  void scheduleProtocolIndexWarmAfterFirstAudioTurn() {
    warmProtocolIndexInBackground();
  }

  Future<bool> _buildVectorIndex() async {
    final storable = _protocols
        .where((p) => '${p.title}\n\n${p.body}'.trim().isNotEmpty)
        .toList();
    if (storable.isEmpty) {
      _vectorIndexReady = true;
      _vectorIndex = const [];
      return true;
    }
    try {
      final chunks = <_VectorChunk>[];
      for (var i = 0; i < storable.length; i++) {
        final p = storable[i];
        final content = '${p.title}\n\n${p.body}';
        chunks.add(_VectorChunk(
          protocolId: p.id,
          content: content,
          embedding: _embedProtocolText1024(content),
        ));
        if (i % 32 == 31) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      _vectorIndex = chunks;
      _vectorIndexReady = true;
      return true;
    } catch (e, st) {
      debugPrint('Protocol vector index failed: $e\n$st');
      _vectorIndexReady = false;
      _vectorIndex = const [];
      return false;
    }
  }

  /// Load the small handcrafted `protocols.json` starter (optional).
  static Future<void> _appendProtocolsFromStarter(
    AssetBundle b,
    List<_ProtocolDoc> sink,
  ) async {
    String raw;
    try {
      raw = await b.loadString('assets/kb/datasets/protocols.json');
    } catch (_) {
      return; // file not bundled — fine
    }
    final root = jsonDecode(raw) as Map<String, dynamic>;
    final dataset =
        (root['dataset_name'] as String? ?? 'Protocols').trim();
    for (final e in (root['entries'] as List<dynamic>? ?? [])) {
      final m = e as Map<String, dynamic>;
      final id = (m['id'] as String? ?? '').trim();
      final title = (m['title'] as String? ?? '').trim();
      final body = (m['body'] as String? ?? '').trim();
      if (id.isEmpty || title.isEmpty || body.isEmpty) continue;
      final tags = (m['tags'] as List<dynamic>? ?? [])
          .map((t) => t.toString().trim())
          .where((t) => t.isNotEmpty)
          .toList();
      sink.add(_ProtocolDoc(
        id: id,
        title: title,
        body: body,
        tags: tags,
        datasetName: dataset,
      ));
    }
  }

  /// Load the chunked JSONL corpus (one JSON object per line).
  /// Silently no-ops if the asset is not bundled.
  static Future<void> _appendProtocolsFromJsonl(
    AssetBundle b,
    String path,
    List<_ProtocolDoc> sink,
  ) async {
    String raw;
    try {
      raw = await b.loadString(path);
    } catch (_) {
      return;
    }

    final lines = const LineSplitter().convert(raw);
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Map<String, dynamic>? obj;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) obj = decoded;
      } catch (_) {
        continue; // skip malformed lines; don't fail the whole load
      }
      if (obj == null) continue;

      final id = (obj['id'] as String? ?? '').trim();
      final text = (obj['text'] as String? ?? '').trim();
      if (id.isEmpty || text.isEmpty) continue;

      final source = (obj['source'] as String? ?? 'First-aid corpus').trim();
      final section = (obj['section'] as String? ?? '').trim();

      final pages = <int>[];
      final pagesRaw = obj['pages'];
      if (pagesRaw is List) {
        for (final p in pagesRaw) {
          if (p is int) {
            pages.add(p);
          } else if (p is num) {
            pages.add(p.toInt());
          }
        }
      }

      final title =
          section.isNotEmpty ? section : 'First-aid reference';

      sink.add(_ProtocolDoc(
        id: id,
        title: title,
        body: text,
        tags: const <String>[],
        datasetName: source,
        pages: pages,
      ));
    }
  }

  @override
  Future<List<ProtocolHit>> searchProtocols(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    if (_liteRtInferenceActive || !_vectorIndexReady) {
      if (!_vectorIndexReady && !_liteRtInferenceActive) {
        warmProtocolIndexInBackground();
      }
      return _fallbackKeywordProtocolSearch(q);
    }

    if (_vectorIndex.isEmpty) {
      return _fallbackKeywordProtocolSearch(q);
    }

    try {
      final qEmb = _embedProtocolText1024(q);
      final ranked = <_Scored<_VectorChunk>>[];
      for (final chunk in _vectorIndex) {
        ranked.add(_Scored(chunk, _dot(qEmb, chunk.embedding)));
      }
      ranked.sort((a, b) => b.score.compareTo(a.score));

      final seenSection = <String>{};
      final out = <ProtocolHit>[];

      for (final hit in ranked.take(24)) {
        final chunk = hit.item;
        final doc = _protocolById[chunk.protocolId];
        if (doc == null) continue;

        final key = '${doc.datasetName}::${doc.title}';
        if (!seenSection.add(key)) continue;

        final chunkText = chunk.content.trim();
        final snip = chunkText.length > 320
            ? '${chunkText.substring(0, 317)}…'
            : (chunkText.isNotEmpty
                ? chunkText
                : (doc.body.length > 320
                    ? '${doc.body.substring(0, 317)}…'
                    : doc.body));

        final score = hit.score.clamp(0.0, 1.0);

        out.add(ProtocolHit(
          title: doc.title,
          snippet: snip,
          score: score,
          citation: KbCitation(
            sourceId: doc.id,
            snippet: snip,
            datasetName: doc.datasetName,
            entryTitle: doc.titleWithPages,
          ),
        ));
        if (out.length >= 3) break;
      }
      return out;
    } catch (e, st) {
      debugPrint('Vector protocol search failed — keyword fallback. $e\n$st');
      return _fallbackKeywordProtocolSearch(q);
    }
  }

  /// When the vector index is not ready, keep basic grounding via substring /
  /// word hits so the gateway is not blind.
  List<ProtocolHit> _fallbackKeywordProtocolSearch(String query) {
    final qWords = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .map((s) => s.trim())
        .where((s) => s.length > 2)
        .toSet();
    if (qWords.length < 2) return const [];

    final scored = <_Scored<_ProtocolDoc>>[];
    for (final doc in _protocols) {
      final hay = '${doc.title} ${doc.body}'.toLowerCase();
      var matched = 0;
      for (final w in qWords) {
        if (hay.contains(w)) matched++;
      }
      if (matched < 2) continue;
      final score = matched / qWords.length;
      if (score < 0.15) continue;
      scored.add(_Scored(doc, score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final seenSection = <String>{};
    final deduped = <_Scored<_ProtocolDoc>>[];
    for (final s in scored) {
      final key = '${s.item.datasetName}::${s.item.title}';
      if (!seenSection.add(key)) continue;
      deduped.add(s);
      if (deduped.length >= 3) break;
    }

    return deduped.map((s) {
      final e = s.item;
      final snip = e.body.length > 320 ? '${e.body.substring(0, 317)}…' : e.body;
      return ProtocolHit(
        title: e.title,
        snippet: snip,
        score: s.score.clamp(0.0, 1.0),
        citation: KbCitation(
          sourceId: e.id,
          snippet: snip,
          datasetName: e.datasetName,
          entryTitle: e.titleWithPages,
        ),
      );
    }).toList();
  }

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
  }) async {
    final signs = observedSigns
        .map((s) => s.toLowerCase().trim())
        .where((s) => s.isNotEmpty)
        .toList();

    _TriageRow? best;
    var bestScore = 0;
    var bestTierWeight = 0;

    for (final rule in _triage) {
      if (!_rulePassesFilters(rule, visibleBleeding, responsiveAppearing)) {
        continue;
      }
      var score = 0;
      for (final sign in signs) {
        for (final term in rule.signTerms) {
          if (sign.contains(term) || term.contains(sign)) score++;
        }
      }
      final tw = _tierWeight(rule.tier);
      if (score > bestScore || (score == bestScore && tw > bestTierWeight)) {
        bestScore = score;
        bestTierWeight = tw;
        best = rule;
      }
    }

    if (best == null || bestScore == 0) return null;

    return TriageRule(
      tier: best.tier,
      rationale: best.rationale,
      citation: KbCitation(
        sourceId: best.id,
        snippet: best.rationale,
        datasetName: triageDatasetName,
        entryTitle: '${_tierShortLabel(best.tier)} — ${best.id}',
      ),
    );
  }

  static bool _rulePassesFilters(
    _TriageRow rule,
    bool visibleBleeding,
    bool? responsiveAppearing,
  ) {
    if (rule.visibleBleeding != null && rule.visibleBleeding != visibleBleeding) {
      return false;
    }
    if (rule.responsiveAppearing != null && responsiveAppearing != null) {
      if (rule.responsiveAppearing != responsiveAppearing) return false;
    }
    return true;
  }

  static int _tierWeight(TriageTier t) {
    switch (t) {
      case TriageTier.red:
        return 3;
      case TriageTier.yellow:
        return 2;
      case TriageTier.green:
        return 1;
    }
  }

  static String _tierShortLabel(TriageTier t) {
    switch (t) {
      case TriageTier.red:
        return 'RED';
      case TriageTier.yellow:
        return 'YELLOW';
      case TriageTier.green:
        return 'GREEN';
    }
  }

}

/// 1024-D signed feature hashing (Murhash-style mixing). All work stays
/// on-device with no extra model download.
List<double> _embedProtocolText1024(String text) {
  final v = List<double>.filled(1024, 0.0);
  final lower = text.toLowerCase();
  final words = lower
      .split(RegExp(r'[^a-z0-9]+'))
      .map((s) => s.trim())
      .where((s) => s.length > 1);

  for (final w in words) {
    _accumulateHashedFeatures(v, w);
    if (w.length >= 4) {
      for (var i = 0; i <= w.length - 4; i++) {
        _accumulateHashedFeatures(v, w.substring(i, i + 4));
      }
    }
  }

  final compact = lower.replaceAll(RegExp(r'[^a-z0-9]'), '');
  for (var i = 0; i < compact.length - 2; i++) {
    _accumulateHashedFeatures(v, compact.substring(i, i + 3));
  }

  var sumSq = 0.0;
  for (final x in v) {
    sumSq += x * x;
  }
  if (sumSq <= 1e-12) {
    const fill = 1.0 / 32.0; // 1 / sqrt(1024)
    for (var i = 0; i < v.length; i++) {
      v[i] = fill;
    }
    return v;
  }
  final inv = 1.0 / sqrt(sumSq);
  for (var i = 0; i < v.length; i++) {
    v[i] *= inv;
  }
  return v;
}

void _accumulateHashedFeatures(List<double> v, String piece) {
  for (var seed = 0; seed < 3; seed++) {
    var h = 0xcbf29ce484222325 ^ seed * 0x100000001b3;
    for (final cu in piece.codeUnits) {
      h = 0x100000001b3 * (h ^ cu);
    }
    final idx = h & 1023;
    final sign = ((h >> 11) & 1) == 0 ? 1.0 : -1.0;
    v[idx] += sign;
  }
}

class _Scored<T> {
  _Scored(this.item, this.score);
  final T item;
  final double score;
}

class _VectorChunk {
  const _VectorChunk({
    required this.protocolId,
    required this.content,
    required this.embedding,
  });

  final String protocolId;
  final String content;
  final List<double> embedding;
}

double _dot(List<double> a, List<double> b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

class _ProtocolDoc {
  _ProtocolDoc({
    required this.id,
    required this.title,
    required this.body,
    required this.tags,
    required this.datasetName,
    this.pages = const <int>[],
  });

  final String id;
  final String title;
  final String body;
  final List<String> tags;
  final String datasetName;
  final List<int> pages;

  /// Section title plus page range when the source provides it —
  /// shown in the citation provenance line so the responder knows
  /// which pages of the reference to consult for the original text.
  String get titleWithPages {
    if (pages.isEmpty) return title;
    final sorted = [...pages]..sort();
    final lo = sorted.first;
    final hi = sorted.last;
    if (lo == hi) return '$title (p. $lo)';
    return '$title (pp. $lo–$hi)';
  }
}

class _TriageRow {
  _TriageRow({
    required this.id,
    required this.tier,
    required this.signTerms,
    required this.rationale,
    this.visibleBleeding,
    this.responsiveAppearing,
  });

  final String id;
  final TriageTier tier;
  final List<String> signTerms;
  final String rationale;
  final bool? visibleBleeding;
  final bool? responsiveAppearing;

  factory _TriageRow.fromJson(Map<String, dynamic> j) {
    final tierRaw = (j['tier'] as String? ?? 'yellow').toLowerCase();
    final tier = switch (tierRaw) {
      'red' => TriageTier.red,
      'green' => TriageTier.green,
      _ => TriageTier.yellow,
    };
    return _TriageRow(
      id: (j['id'] as String? ?? '').trim(),
      tier: tier,
      signTerms: (j['sign_terms'] as List<dynamic>? ?? [])
          .map((e) => e.toString().toLowerCase().trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      rationale: (j['rationale'] as String? ?? '').trim(),
      visibleBleeding: j['visible_bleeding'] as bool?,
      responsiveAppearing: j['responsive_appearing'] as bool?,
    );
  }
}
