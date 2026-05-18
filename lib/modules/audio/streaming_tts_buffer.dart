import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../services/session_log.dart';
import '../tools/tool_call_parser.dart';
import 'multilingual_tts.dart';

/// Accumulates Gemma tokens and fires TTS as soon as each sentence ends.
///
/// Flow: Gemma token → [onToken] → buffer → sentence boundary →
/// [MultilingualTTS.speakSentence] → speech output.
///
/// Sentence boundaries: `.` `!` `?` `۔` `؟` `।` plus double-newline.
/// A max-buffer guard flushes overly long fragments so TTS never falls
/// more than ~400 chars behind the model.
class StreamingTtsBuffer {
  StreamingTtsBuffer({
    required MultilingualTTS tts,
    int maxBufferChars = 400,
  })  : _tts = tts,
        _maxBufferChars = maxBufferChars;

  final MultilingualTTS _tts;
  final int _maxBufferChars;

  final List<String> _buf = <String>[];
  int _charCount = 0;
  bool _started = false;
  String _language = 'en';
  bool _cancelled = false;

  /// Total sentences queued to TTS in this streaming turn.
  int get sentencesQueued => _sentencesQueued;
  int _sentencesQueued = 0;

  /// Call once before the first token of a new model turn.
  void begin({required String language}) {
    _buf.clear();
    _charCount = 0;
    _started = false;
    _cancelled = false;
    _sentencesQueued = 0;
    _language = language;
  }

  /// Feed one streamed chunk from Gemma. May trigger TTS immediately.
  Future<void> onToken(String token) async {
    if (_cancelled) return;
    if (token.isEmpty) return;

    if (!_started) {
      _started = true;
      unawaited(SessionLog.instance?.streamingTtsStart());
    }

    _buf.add(token);
    _charCount += token.length;

    if (_hitsSentenceBoundary(token) || _charCount >= _maxBufferChars) {
      await _flush();
    }
  }

  /// Flush any remaining buffered text (call after Gemma stream ends).
  Future<void> finish() async {
    if (_cancelled) return;
    if (_buf.isNotEmpty) {
      await _flush();
    }
    unawaited(SessionLog.instance?.streamingTtsComplete());
  }

  /// Discard buffer and stop further TTS from this turn.
  void cancel() {
    _cancelled = true;
    _buf.clear();
    _charCount = 0;
  }

  // ---------------------------------------------------------------------------

  Future<void> _flush() async {
    if (_buf.isEmpty) return;
    final raw = _buf.join();
    _buf.clear();
    _charCount = 0;

    final cleaned = _cleanForTts(raw);
    if (cleaned.isEmpty) return;

    _sentencesQueued++;
    unawaited(SessionLog.instance?.sentenceQueuedToTts(cleaned));
    // Queue only — never block the Gemma token loop on playback.
    unawaited(
      _tts.speakSentence(text: cleaned, language: _language).catchError(
        (Object e) => debugPrint('StreamingTtsBuffer: TTS failed: $e'),
      ),
    );
  }

  /// Strip tool-call XML and collapse whitespace; don't truncate — each
  /// sentence is already short.
  static String _cleanForTts(String raw) {
    var t = ToolCallExtractor.stripFromText(raw);
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  static bool _hitsSentenceBoundary(String token) {
    if (token.isEmpty) return false;
    // Check last 2 chars (token may be multi-char).
    final tail =
        token.length > 2 ? token.substring(token.length - 2) : token;
    for (int i = 0; i < tail.length; i++) {
      final c = tail[i];
      if (_kSentenceEnders.contains(c)) return true;
    }
    if (token.contains('\n\n')) return true;
    return false;
  }

  /// Period, exclamation, question — English, Urdu, Hindi, Arabic.
  static const Set<String> _kSentenceEnders = {
    '.', '!', '?',       // English / Latin
    '۔', '؟',            // Urdu
    '।',                  // Hindi / Devanagari danda
    '？', '！', '。',     // CJK fullwidth (defensive)
  };
}
