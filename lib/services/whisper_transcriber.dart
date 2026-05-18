import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import 'language_detector.dart';
import 'whisper_assets.dart';

/// Keys in the map returned by [WhisperTranscriber.transcribeAudio].
abstract final class WhisperTranscriptionKeys {
  static const String text = 'text';
  static const String language = 'language';
  static const String confidence = 'confidence';
}

/// Offline CPU Whisper Tiny transcription via whisper.cpp / GGML.
///
/// Uses `language: auto` for Whisper; detected language is inferred from
/// the transcript script (see [LanguageDetector]).
class WhisperTranscriber {
  WhisperTranscriber();

  final WhisperController _controller = WhisperController();
  String? _modelPath;
  bool _disposed = false;
  Future<void> _serial = Future<void>.value();

  Future<void> initialize() async {
    if (_disposed) throw StateError('WhisperTranscriber disposed.');
    if (_modelPath != null) return;
    _modelPath = await WhisperAssets.resolveModelPath();
    await _controller.initModel(WhisperModel.tiny);
  }

  /// Transcribe [audioBytes] (16 kHz mono WAV). Returns
  /// `{text, language, confidence}` — language is `ur`, `en`, or `unknown`.
  Future<Map<String, dynamic>> transcribeAudio(Uint8List audioBytes) async {
    if (_disposed) throw StateError('WhisperTranscriber disposed.');
    if (audioBytes.length < 1024) {
      return {
        WhisperTranscriptionKeys.text: '',
        WhisperTranscriptionKeys.language: LanguageDetector.unknown,
        WhisperTranscriptionKeys.confidence: 0.0,
      };
    }

    final completer = Completer<Map<String, dynamic>>();
    _serial = _serial.then((_) async {
      try {
        completer.complete(await _transcribeAudioImpl(audioBytes));
      } catch (e, st) {
        debugPrint('WhisperTranscriber.transcribeAudio failed: $e\n$st');
        if (!completer.isCompleted) {
          completer.complete({
            WhisperTranscriptionKeys.text: '',
            WhisperTranscriptionKeys.language: LanguageDetector.unknown,
            WhisperTranscriptionKeys.confidence: 0.0,
          });
        }
      }
    });
    return completer.future;
  }

  Future<Map<String, dynamic>> _transcribeAudioImpl(Uint8List audioBytes) async {
    await initialize();

    final cacheDir = await getTemporaryDirectory();
    final wavPath =
        '${cacheDir.path}/whisper_in_${DateTime.now().microsecondsSinceEpoch}.wav';
    final wavFile = File(wavPath);

    try {
      await wavFile.writeAsBytes(audioBytes, flush: true);

      const whisper = Whisper(model: WhisperModel.tiny);
      final response = await whisper.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: wavPath,
          language: 'auto',
          isTranslate: false,
          isNoTimestamps: true,
          isRealtime: false,
          threads: 2,
          nProcessors: 1,
          splitOnWord: false,
        ),
        modelPath: _modelPath!,
      );

      final text = response.text.trim();
      final detected = LanguageDetector.detectFromText(text);
      var lang = LanguageDetector.normalizeForPipeline(detected.language);
      if (lang == LanguageDetector.unknown) {
        lang = LanguageDetector.english;
      }

      return {
        WhisperTranscriptionKeys.text: text,
        WhisperTranscriptionKeys.language: lang,
        WhisperTranscriptionKeys.confidence: detected.confidence,
      };
    } finally {
      for (final path in <String>[wavPath, '$wavPath.wav']) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {
          // best-effort
        }
      }
    }
  }

  void dispose() {
    _disposed = true;
    _modelPath = null;
  }
}
