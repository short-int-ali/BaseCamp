import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_tts/flutter_tts.dart';

import '../tools/tool_call_parser.dart';

/// Thrown when the platform TTS engine does not offer a voice for the
/// requested locale.
class VoiceMissingException implements Exception {
  VoiceMissingException({required this.searched});

  final List<String> searched;

  @override
  String toString() =>
      'VoiceMissingException: no system TTS voice for this locale. '
      'Tried: ${searched.join(", ")}';
}

/// Device TTS via `flutter_tts` (out-of-process on Android).
class SpeechSynth {
  SpeechSynth({this.language = 'en-US'});

  final String language;
  final FlutterTts _tts = FlutterTts();

  int _speakVersion = 0;
  bool _ready = false;
  bool _speaking = false;

  final StreamController<void> _utteranceCompletions =
      StreamController<void>.broadcast();
  Stream<void> get utteranceCompletions => _utteranceCompletions.stream;

  bool get isInitialized => _ready;
  bool get isSpeaking => _speaking;

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

    // When true, `speak()` does not return until playback finishes (on
    // most platforms). This is more reliable than CompletionHandler
    // alone on Transsion / MediaTek builds.
    await _tts.awaitSpeakCompletion(true);

    _tts.setCompletionHandler(() {
      debugPrint('SpeechSynth: completion handler');
    });
    _tts.setErrorHandler((msg) {
      debugPrint('SpeechSynth: TTS error: $msg');
    });

    final searched = <String>[];
    final resolved = await _pickAvailableLanguage(searched);
    if (resolved == null) {
      throw VoiceMissingException(searched: searched);
    }

    await _tts.setLanguage(resolved);
    // Android: 1.0 is normal speed; lower is slower. 0.52 is ~half
    // speed on Google TTS and is easier to follow during emergencies.
    if (Platform.isAndroid) {
      await _tts.setSpeechRate(0.52);
    } else {
      await _tts.setSpeechRate(0.45);
    }
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _ready = true;
    debugPrint('SpeechSynth: ready lang=$resolved');
  }

  Future<void> _configureAndroidEngine() async {
    try {
      final def = await _tts.getDefaultEngine;
      if (def != null && def.toString().trim().isNotEmpty) {
        await _tts.setEngine(def.toString());
        debugPrint('SpeechSynth: defaultEngine=$def');
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
        debugPrint('SpeechSynth: engine=$chosen');
      }
    } catch (e) {
      debugPrint('SpeechSynth: engine setup failed (using OEM default): $e');
    }
  }

  Future<String?> _pickAvailableLanguage(List<String> searched) async {
    final primary = language.trim();
    final candidates = <String>[
      if (primary.isNotEmpty) primary,
      if (primary.contains('-')) primary.replaceAll('-', '_'),
      'en-US',
      'en_US',
      'en-GB',
      if (primary.toLowerCase().startsWith('ur')) 'ur-PK',
    ];

    for (final tag in candidates) {
      searched.add(tag);
      try {
        final ok = await _tts.isLanguageAvailable(tag);
        if (ok == true) return tag;
      } catch (_) {
        // try next
      }
    }
    return null;
  }

  /// Plain text for TTS — strips tool tags and caps length for OEM limits.
  static String textForSpeech(String raw) {
    var t = ToolCallExtractor.stripFromText(raw);
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    const marker = 'This is guidance, not a medical diagnosis';
    final idx = t.indexOf(marker);
    if (idx > 80) {
      t = t.substring(0, idx).trim();
    }
    if (t.length > 900) {
      t = '${t.substring(0, 897)}...';
    }
    return t;
  }

  Future<void> speak(String text) async {
    if (!_ready) await initialize();
    final clean = textForSpeech(text);
    if (clean.isEmpty) {
      debugPrint('SpeechSynth: speak skipped (empty after sanitize)');
      return;
    }

    final mine = ++_speakVersion;

    if (_speaking) {
      try {
        await _tts.stop();
      } catch (_) {
        // best-effort
      }
      _speaking = false;
    }

    _speaking = true;
    debugPrint('SpeechSynth: speak start (${clean.length} chars)');

    try {
      if (Platform.isAndroid) {
        await _tts.setSpeechRate(0.52);
      }
      final result = await _tts.speak(clean);
      if (mine != _speakVersion) return;
      if (result == 0) {
        debugPrint('SpeechSynth: speak() returned failure (0)');
      } else {
        debugPrint('SpeechSynth: speak() finished (result=$result)');
      }
    } catch (e, st) {
      debugPrint('SpeechSynth.speak failed: $e\n$st');
    } finally {
      if (mine == _speakVersion) {
        _speaking = false;
        _fireCompletion();
      }
    }
  }

  Future<void> stop() async {
    _speakVersion++;
    final wasSpeaking = _speaking;
    _speaking = false;
    try {
      await _tts.stop();
    } catch (_) {
      // best-effort
    }
    if (wasSpeaking) _fireCompletion();
  }

  Future<void> dispose() async {
    _speakVersion++;
    _speaking = false;
    try {
      await _tts.stop();
    } catch (_) {
      // best-effort
    }
    _ready = false;
    if (!_utteranceCompletions.isClosed) {
      await _utteranceCompletions.close();
    }
  }
}
