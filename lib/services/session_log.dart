import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import '../database/medical_kb.dart';
import '../modules/vision/vision_result.dart';
import 'session_end_result.dart';
import 'session_log_paths.dart';
import 'session_log_pdf_exporter.dart';

/// Direct-to-disk ASK session log. One open file per session; each
/// event is a single flushed line (no RAM buffer).
class SessionLog {
  SessionLog._(this._file, this._sink, this._startedAt);

  static SessionLog? _active;

  /// The live session logger, if any.
  static SessionLog? get instance => _active;

  final File _file;
  final IOSink _sink;
  final DateTime _startedAt;

  int _turnCount = 0;
  TriageTier? _lastTriage;
  final List<String> _toolsUsed = <String>[];

  File get file => _file;
  bool get isActive => true;

  /// Ensures a log file is open; starts one if the prior session ended.
  static Future<SessionLog> ensureActive() async {
    final existing = _active;
    if (existing != null) return existing;
    return start();
  }

  /// Opens `session_logs/session_yyyyMMdd_HHmmss.txt` under app external
  /// files (streamed via [IOSink], flush per line).
  static Future<SessionLog> start() async {
    if (_active != null) {
      await _active!.endSession(reason: 'restarted');
    }

    final dir = await SessionLogPaths.txtDirectory();
    final stamp = _fileStamp(DateTime.now());
    final file = File('${dir.path}/session_$stamp.txt');
    final sink = file.openWrite(mode: FileMode.writeOnly);

    final log = SessionLog._(file, sink, DateTime.now());
    _active = log;

    await log._writeRaw('Base Camp Session Log');
    await log._writeRaw('Started: ${_headerStamp(log._startedAt)}');
    await log._writeRaw('File: ${file.path}');
    await log._writeRaw('---');

    return log;
  }

  static Future<SessionEndResult?> endIfActive({String reason = 'app_exit'}) async {
    final log = _active;
    if (log == null) return null;
    return log.endSession(reason: reason);
  }

  Future<void> turnStart() async {
    _turnCount++;
    await _event('TURN_START');
  }

  Future<void> userAudio(String transcript) async {
    await _event('USER_AUDIO', transcript);
  }

  /// Whisper STT result for an audio turn (offline GGML).
  Future<void> userAudioTranscribed(String transcript) async {
    await _event('USER_AUDIO_TRANSCRIBED', transcript);
  }

  Future<void> userLanguageDetected(String languageCode) async {
    await _event('USER_LANGUAGE_DETECTED', languageCode);
  }

  Future<void> ttsFallbackUrduToEnglish() async {
    await _event('TTS_FALLBACK', 'ur→en');
  }

  Future<void> gemmaStart() async {
    await _event('GEMMA_START');
  }

  Future<void> gemmaResponse(String text) async {
    await _event('GEMMA_RESPONSE', text);
  }

  Future<void> triage(TriageTier tier) async {
    _lastTriage = tier;
    await _event('TRIAGE', tier.label);
  }

  Future<void> sourcesFromHits(List<ProtocolHit> hits) async {
    if (hits.isEmpty) return;
    for (final h in hits.take(3)) {
      final c = h.citation;
      final pages = _pagesFromTitle(c.entryTitle);
      final section = c.entryTitle ?? h.title;
      final ds = c.datasetName ?? 'KB';
      await _event('SOURCES', '$ds|$section|$pages');
      await _event('RAG_CONFIDENCE', _confidenceLabel(h.score));
    }
  }

  Future<void> agenticCall(String toolName) async {
    if (_toolsUsed.isEmpty || _toolsUsed.last != toolName) {
      _toolsUsed.add(toolName);
    }
    await _event('AGENTIC_CALL', toolName);
  }

  Future<void> userResponse(bool yes) async {
    await _event('USER_RESPONSE', yes ? 'yes' : 'no');
  }

  Future<void> toolExecuted(String outcome) async {
    await _event('TOOL_EXECUTED', outcome);
  }

  Future<void> cameraModalRequested(String label) async {
    await _event('CAMERA_MODAL_REQUESTED', label);
  }

  /// Metadata only — never logs image bytes.
  Future<void> cameraImageCaptured({required int byteLength}) async {
    await _event('CAMERA_IMAGE_CAPTURED', 'bytes=$byteLength');
  }

  Future<void> cameraImageInjected() async {
    await _event('CAMERA_IMAGE_INJECTED');
  }

  Future<void> cameraCancelled() async {
    await _event('CAMERA_CANCELLED');
  }

  Future<void> streamingTtsStart() async {
    await _event('STREAMING_TTS_START', 'first token received');
  }

  Future<void> sentenceQueuedToTts(String sentence) async {
    await _event('SENTENCE_QUEUED_TO_TTS', sentence);
  }

  Future<void> streamingTtsComplete() async {
    await _event('STREAMING_TTS_COMPLETE');
  }

  Future<void> turnEnd() async {
    await _event('TURN_END');
  }

  /// Closes the TXT log, exports PDF to app `Basecamp` folder, deletes TXT
  /// on success. Returns paths and user-facing status message.
  Future<SessionEndResult> endSession({String reason = 'user'}) async {
    final duration = DateTime.now().difference(_startedAt);
    final triage = _lastTriage?.label ?? 'none';
    final tools = _toolsUsed.isEmpty ? 'none' : _toolsUsed.join(', ');

    if (_active == this) {
      await _event('SESSION_END', reason);
      await _writeRaw('---');
      await _writeRaw('Session summary');
      await _writeRaw('Duration: ${_formatDuration(duration)}');
      await _writeRaw('Turns: $_turnCount');
      await _writeRaw('Final triage: $triage');
      await _writeRaw('Tools used: $tools');
      await _writeRaw('Ended: ${_headerStamp(DateTime.now())}');

      try {
        await _sink.flush();
        await _sink.close();
      } catch (e) {
        debugPrint('SessionLog.close failed: $e');
      }
      _active = null;
    }

    return SessionLogPdfExporter.convertAndArchive(
      txtPath: _file.path,
      startedAt: _startedAt,
      turnCount: _turnCount,
      finalTriage: triage,
      toolsUsed: tools,
    );
  }

  Future<void> _event(String tag, [String? value]) async {
    final v = value == null ? tag : '$tag: ${_sanitize(value)}';
    await _writeLine(v);
  }

  Future<void> _writeLine(String body) async {
    final ts = _lineStamp(DateTime.now());
    await _writeRaw('[$ts] $body');
  }

  Future<void> _writeRaw(String line) async {
    _sink.writeln(line);
    await _sink.flush();
  }

  static String _sanitize(String raw) {
    final oneLine = raw.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (oneLine.length <= 200) return oneLine;
    return '${oneLine.substring(0, 197)}...';
  }

  static String _confidenceLabel(double score) {
    if (score >= 0.6) return 'high';
    if (score >= 0.3) return 'medium';
    return 'low';
  }

  static String _pagesFromTitle(String? title) {
    if (title == null) return '';
    final m = RegExp(r'pp\.\s*([\d–\-]+)').firstMatch(title);
    return m?.group(1) ?? '';
  }

  static String _fileStamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y$mo${d}_$h$mi$s';
  }

  static String _lineStamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$mi:$s';
  }

  static String _headerStamp(DateTime dt) => dt.toIso8601String();

  static String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m}m $s s';
  }
}
