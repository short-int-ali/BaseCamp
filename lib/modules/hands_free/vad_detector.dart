import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'sherpa_assets.dart';
import 'sherpa_init.dart';

/// Lifecycle event from the VAD.
enum VadEventKind { speechStart, speechEnd }

/// One VAD lifecycle event. For [VadEventKind.speechEnd] [samples]
/// holds the full Float32 segment the detector emitted (mic-rate, 16
/// kHz mono); for [VadEventKind.speechStart] [samples] is empty.
class VadEvent {
  const VadEvent({required this.kind, required this.samples});
  final VadEventKind kind;
  final Float32List samples;

  static VadEvent start() =>
      VadEvent(kind: VadEventKind.speechStart, samples: Float32List(0));
  static VadEvent end(Float32List samples) =>
      VadEvent(kind: VadEventKind.speechEnd, samples: samples);
}

/// Streaming Silero VAD wrapper. Mirrors the chunking pattern from
/// `dart-api-examples/vad/bin/vad.dart`: caller streams Float32 frames
/// in, we slice them into Silero's window-size chunks, push to the
/// detector, then drain `front()` segments.
///
/// The class also synthesizes a `speechStart` event the first time
/// `isDetected()` flips true after silence, since the underlying
/// sherpa API only surfaces completed segments. The orchestrator
/// uses `speechStart` to splice in the 600 ms pre-roll buffer.
class VadDetector {
  VadDetector({
    required SherpaAssetPaths paths,
    double threshold = 0.5,
    double minSilenceDuration = 0.7,
    double minSpeechDuration = 0.25,
    double maxSpeechDurationSec = 30.0,
    int bufferSizeInSeconds = 30,
  })  : _paths = paths,
        _threshold = threshold,
        _minSilenceDuration = minSilenceDuration,
        _minSpeechDuration = minSpeechDuration,
        _maxSpeechDuration = maxSpeechDurationSec,
        _bufferSizeInSeconds = bufferSizeInSeconds;

  final SherpaAssetPaths _paths;
  final double _threshold;
  final double _minSilenceDuration;
  final double _minSpeechDuration;
  final double _maxSpeechDuration;
  final int _bufferSizeInSeconds;

  sherpa_onnx.VoiceActivityDetector? _vad;
  int _windowSize = 512;

  /// Carries leftover samples between [feed] calls so we always push
  /// exactly window-size chunks. Silero is sensitive to chunk size —
  /// the model is trained at 512-sample windows.
  Float32List _carry = Float32List(0);

  /// Track whether the previous chunk saw `isDetected == true` so we
  /// can synthesize one-shot `speechStart` events.
  bool _wasDetected = false;
  bool _disposed = false;

  /// Sample rate the detector expects. Caller must match.
  static const int kSampleRate = 16000;

  Future<void> initialize() async {
    if (_disposed) {
      throw StateError('VadDetector already disposed.');
    }
    if (_vad != null) return;

    ensureSherpaOnnxInitialized();

    final silero = sherpa_onnx.SileroVadModelConfig(
      model: _paths.vadSileroVad,
      threshold: _threshold,
      minSilenceDuration: _minSilenceDuration,
      minSpeechDuration: _minSpeechDuration,
      maxSpeechDuration: _maxSpeechDuration,
    );
    _windowSize = silero.windowSize;

    final config = sherpa_onnx.VadModelConfig(
      sileroVad: silero,
      sampleRate: kSampleRate,
      numThreads: 1,
      debug: false,
    );

    _vad = sherpa_onnx.VoiceActivityDetector(
      config: config,
      bufferSizeInSeconds: _bufferSizeInSeconds.toDouble(),
    );
  }

  /// Feed [samples] (Float32, 16 kHz mono) into the VAD. Returns the
  /// lifecycle events produced by this chunk in order: zero or one
  /// `speechStart`, zero or more `speechEnd`s. The orchestrator
  /// consumes these to drive its turn buffer.
  List<VadEvent> feed(Float32List samples) {
    if (_disposed) return const <VadEvent>[];
    final vad = _vad;
    if (vad == null || samples.isEmpty) return const <VadEvent>[];

    final events = <VadEvent>[];

    final combined = _appendCarry(samples);
    final win = _windowSize;
    final n = combined.length;
    final usable = n - (n % win);

    try {
      for (int i = 0; i < usable; i += win) {
        final chunk = Float32List.sublistView(combined, i, i + win);
        vad.acceptWaveform(chunk);

        // Edge-trigger speechStart: the moment isDetected flips from
        // false to true, emit a synthetic event so the orchestrator
        // can splice in pre-roll. We do this AFTER acceptWaveform so
        // the detector state reflects this chunk's contribution.
        final detected = vad.isDetected();
        if (detected && !_wasDetected) {
          events.add(VadEvent.start());
        }
        _wasDetected = detected;

        // Drain any completed segments. Multiple segments per chunk
        // are rare but possible if the buffer overran or the user
        // paused mid-utterance.
        while (!vad.isEmpty()) {
          final seg = vad.front();
          // Copy out — front() returns a view backed by sherpa's
          // arena, and pop() invalidates it.
          final copy = Float32List.fromList(seg.samples);
          vad.pop();
          events.add(VadEvent.end(copy));
        }
      }
    } catch (e, st) {
      debugPrint('VadDetector.feed failed: $e\n$st');
    }

    // Hold over the tail (less than one window) for the next call.
    _carry = (usable < n)
        ? Float32List.fromList(combined.sublist(usable))
        : Float32List(0);

    return events;
  }

  /// Force any in-progress speech to flush as a final segment. The
  /// orchestrator calls this when the 30 s cap fires so the user's
  /// last syllables make it into the WAV that's handed to Gemma.
  List<VadEvent> flush() {
    if (_disposed) return const <VadEvent>[];
    final vad = _vad;
    if (vad == null) return const <VadEvent>[];
    final events = <VadEvent>[];
    try {
      vad.flush();
      while (!vad.isEmpty()) {
        final seg = vad.front();
        final copy = Float32List.fromList(seg.samples);
        vad.pop();
        events.add(VadEvent.end(copy));
      }
    } catch (e) {
      debugPrint('VadDetector.flush failed: $e');
    }
    _wasDetected = false;
    _carry = Float32List(0);
    return events;
  }

  /// Drop carried state and any queued segments. Called between
  /// hands-free turns so leftover audio from the previous turn
  /// doesn't bleed in.
  void reset() {
    final vad = _vad;
    if (vad == null) return;
    try {
      vad.reset();
      vad.clear();
    } catch (e) {
      debugPrint('VadDetector.reset failed: $e');
    }
    _wasDetected = false;
    _carry = Float32List(0);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _vad?.free();
    } catch (_) {
      // best-effort
    }
    _vad = null;
    _carry = Float32List(0);
  }

  Float32List _appendCarry(Float32List samples) {
    if (_carry.isEmpty) return samples;
    final out = Float32List(_carry.length + samples.length);
    out.setRange(0, _carry.length, _carry);
    out.setRange(_carry.length, out.length, samples);
    return out;
  }
}
