import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_tts/flutter_tts.dart';

import '../../services/language_detector.dart';
import '../../services/session_log.dart';
import 'speech_synth.dart';

/// Result of [MultilingualTTS.speakInLanguage].
class TtsSpeakResult {
  const TtsSpeakResult({
    required this.spokenLanguageTag,
    required this.usedEnglishFallback,
  });

  final String spokenLanguageTag;
  final bool usedEnglishFallback;
}

/// Device TTS with Urdu-first voice selection and English fallback.
class MultilingualTTS {
  MultilingualTTS();

  final FlutterTts _tts = FlutterTts();

  int _speakVersion = 0;
  bool _ready = false;
  bool _speaking = false;

  final StreamController<void> _utteranceCompletions =
      StreamController<void>.broadcast();
  Stream<void> get utteranceCompletions => _utteranceCompletions.stream;

  bool get isInitialized => _ready;
  bool get isSpeaking => _speaking;

  static const String kUrduVoiceTag = 'ur-PK';
  static const String kEnglishVoiceTag = 'en-US';
  static const String kTtsFallbackBanner =
      'Voice in English — text in Urdu';

  void _fireCompletion() {
    if (_utteranceCompletions.isClosed) return;
    _utteranceCompletions.add(null);
  }

  Future<void> initialize() async {
    if (_ready) return;

    if (Platform.isAndroid) {
      await _tts.setQueueMode(1);
      await _configureAndroidEngine();
    }

    await _tts.awaitSpeakCompletion(true);
    _tts.setCompletionHandler(() {
      debugPrint('MultilingualTTS: completion handler');
    });
    _tts.setErrorHandler((msg) {
      debugPrint('MultilingualTTS: TTS error: $msg');
    });

    if (Platform.isAndroid) {
      await _tts.setSpeechRate(0.52);
    } else {
      await _tts.setSpeechRate(0.45);
    }
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _ready = true;
    debugPrint('MultilingualTTS: ready');
  }

  Future<void> _configureAndroidEngine() async {
    try {
      final def = await _tts.getDefaultEngine;
      if (def != null && def.toString().trim().isNotEmpty) {
        await _tts.setEngine(def.toString());
        return;
      }
      final engines = await _tts.getEngines;
      if (engines is List && engines.isNotEmpty) {
        String? chosen;
        for (final raw in engines) {
          final name = raw.toString();
          if (name.toLowerCase().contains('google')) {
            chosen = name;
            break;
          }
        }
        chosen ??= engines.first.toString();
        await _tts.setEngine(chosen);
      }
    } catch (e) {
      debugPrint('MultilingualTTS: engine setup failed: $e');
    }
  }

  Future<bool> isLanguageAvailable(String tag) async {
    try {
      final ok = await _tts.isLanguageAvailable(tag);
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// Speak [text] using a voice for [language] (`ur`, `en`, or `unknown`).
  Future<TtsSpeakResult> speakInLanguage({
    required String text,
    required String language,
  }) async {
    if (!_ready) await initialize();

    final clean = SpeechSynth.textForSpeech(text);
    if (clean.isEmpty) {
      return const TtsSpeakResult(
        spokenLanguageTag: kEnglishVoiceTag,
        usedEnglishFallback: false,
      );
    }

    final code = LanguageDetector.normalizeForPipeline(language);
    var spokenTag = kEnglishVoiceTag;
    var usedFallback = false;

    if (code == LanguageDetector.urdu) {
      if (await isLanguageAvailable(kUrduVoiceTag)) {
        spokenTag = kUrduVoiceTag;
        await _tts.setLanguage(kUrduVoiceTag);
      } else {
        usedFallback = true;
        spokenTag = kEnglishVoiceTag;
        await _tts.setLanguage(kEnglishVoiceTag);
        final log = SessionLog.instance;
        if (log != null) {
          await log.ttsFallbackUrduToEnglish();
        }
        debugPrint('MultilingualTTS: TTS_FALLBACK_URDU_TO_ENGLISH');
      }
    } else {
      spokenTag = kEnglishVoiceTag;
      await _tts.setLanguage(kEnglishVoiceTag);
    }

    await _speakRaw(clean);

    return TtsSpeakResult(
      spokenLanguageTag: spokenTag,
      usedEnglishFallback: usedFallback,
    );
  }

  Future<void> _speakRaw(String clean) async {
    final mine = ++_speakVersion;

    if (_speaking) {
      try {
        await _tts.stop();
      } catch (_) {}
      _speaking = false;
    }

    _speaking = true;
    try {
      if (Platform.isAndroid) {
        await _tts.setSpeechRate(0.52);
      }
      await _tts.speak(clean);
    } catch (e, st) {
      debugPrint('MultilingualTTS.speak failed: $e\n$st');
    } finally {
      if (mine == _speakVersion) {
        _speaking = false;
        _fireCompletion();
      }
    }
  }

  /// Enqueue a sentence for TTS **without** stopping current playback.
  ///
  /// On Android `setQueueMode(1)` makes `speak()` additive; with
  /// [awaitSpeakCompletion] false, this returns immediately so the
  /// Gemma stream is not blocked waiting for playback.
  Future<void> speakSentence({
    required String text,
    required String language,
  }) async {
    if (!_ready) await initialize();

    final clean = SpeechSynth.textForSpeech(text);
    if (clean.isEmpty) return;

    final code = LanguageDetector.normalizeForPipeline(language);
    if (code == LanguageDetector.urdu) {
      if (await isLanguageAvailable(kUrduVoiceTag)) {
        await _tts.setLanguage(kUrduVoiceTag);
      } else {
        await _tts.setLanguage(kEnglishVoiceTag);
      }
    } else {
      await _tts.setLanguage(kEnglishVoiceTag);
    }

    try {
      if (Platform.isAndroid) {
        await _tts.setSpeechRate(0.52);
      }
      // Do not block the caller until the utterance finishes.
      await _tts.awaitSpeakCompletion(false);
      _speaking = true;
      await _tts.speak(clean);
    } catch (e) {
      debugPrint('MultilingualTTS.speakSentence failed: $e');
    }
  }

  Future<void> stop() async {
    _speakVersion++;
    final wasSpeaking = _speaking;
    _speaking = false;
    try {
      await _tts.stop();
    } catch (_) {}
    if (wasSpeaking) _fireCompletion();
  }

  Future<void> dispose() async {
    _speakVersion++;
    _speaking = false;
    try {
      await _tts.stop();
    } catch (_) {}
    _ready = false;
    if (!_utteranceCompletions.isClosed) {
      await _utteranceCompletions.close();
    }
  }
}
