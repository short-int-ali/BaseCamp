import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:record/record.dart';

import '../../services/whisper_assets.dart';
import '../../services/whisper_transcriber.dart';
import '../audio/audio_gateway.dart';
import '../audio/conversation_turn.dart';
import '../audio/multilingual_tts.dart';
import 'hands_free_state.dart';
import 'sherpa_assets.dart';
import 'sherpa_init.dart';
import 'vad_detector.dart';

/// VAD-driven hands-free loop: continuous mic, 2 s silence ends a turn,
/// [AudioGateway] runs Whisper STT then Gemma on the transcript.
class HandsFreeOrchestrator {
  HandsFreeOrchestrator({
    required AudioGateway gateway,
    required MultilingualTTS tts,
    required WhisperTranscriber whisper,
    AudioRecorder? recorder,
    double silenceTriggerSeconds = kSilenceTriggerSeconds,
  })  : _gateway = gateway,
        _tts = tts,
        _whisper = whisper,
        _recorder = recorder ?? AudioRecorder(),
        _silenceTriggerSeconds = silenceTriggerSeconds;

  final AudioGateway _gateway;
  final MultilingualTTS _tts;
  final WhisperTranscriber _whisper;
  final AudioRecorder _recorder;
  final double _silenceTriggerSeconds;

  static const int _sampleRate = 16000;
  static const Duration _preRollWindow = Duration(milliseconds: 900);
  static const Duration _turnHardCap = Duration(seconds: 30);
  static const Duration _errorRecovery = Duration(seconds: 3);
  static const Duration _speakingCeiling = Duration(seconds: 90);

  SherpaAssetPaths? _sherpaPaths;
  VadDetector? _vad;

  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<GatewaySnapshot>? _gatewaySub;
  StreamSubscription<void>? _synthSub;
  Timer? _turnHardCapTimer;
  Timer? _errorRecoveryTimer;
  Timer? _speakingCeilingTimer;

  final List<Float32List> _preRoll = <Float32List>[];
  int _preRollSamples = 0;
  static int get _preRollCapacity =>
      (_sampleRate * _preRollWindow.inMilliseconds) ~/ 1000;

  final List<Float32List> _turnBuffer = <Float32List>[];
  int _turnSamples = 0;
  bool _preRollSpliced = false;
  bool _turnFinalized = false;

  HandsFreeSnapshot _snap = HandsFreeSnapshot.disarmed;
  final StreamController<HandsFreeSnapshot> _snapshots =
      StreamController<HandsFreeSnapshot>.broadcast();

  Stream<HandsFreeSnapshot> get snapshots => _snapshots.stream;
  HandsFreeSnapshot get current => _snap;
  HandsFreeStage get stage => _snap.stage;

  bool _busy = false;
  bool _disposed = false;
  bool _micPausedForTts = false;
  bool _wasThinking = false;

  Future<void> arm() async {
    if (_disposed) {
      throw StateError('HandsFreeOrchestrator already disposed.');
    }
    if (stage != HandsFreeStage.disarmed) return;
    if (_busy) return;
    _busy = true;
    try {
      _setStage(
        HandsFreeStage.booting,
        statusLine: 'Warming up voice models…',
        clearError: true,
      );

      await _whisper.initialize();
      _sherpaPaths = await SherpaAssets.resolve();

      ensureSherpaOnnxInitialized();
      _vad = VadDetector(
        paths: _sherpaPaths!,
        threshold: 0.5,
        minSilenceDuration: _silenceTriggerSeconds,
        minSpeechDuration: 0.25,
        maxSpeechDurationSec: _turnHardCap.inSeconds.toDouble(),
      );
      await _vad!.initialize();

      _wasThinking = _gateway.current.isThinking;
      _gatewaySub = _gateway.snapshots.listen(_onGatewaySnapshot);
      _synthSub = _tts.utteranceCompletions.listen(_onUtteranceComplete);

      if (!await _recorder.hasPermission()) {
        await _failBackToDisarmed('Microphone permission denied.');
        return;
      }
      await _startMicStream();

      _setStage(
        HandsFreeStage.listening,
        statusLine:
            'Listening… pause ${_silenceTriggerSeconds.toStringAsFixed(0)}s to send.',
        clearError: true,
      );
      _turnHardCapTimer?.cancel();
      _turnHardCapTimer = Timer(_turnHardCap, _flushAndSubmitTurn);
    } on WhisperModelMissingException catch (e) {
      await _failBackToDisarmed(
        'Whisper model not installed.\n\n'
        'See assets/whisper/README.md. Tap-to-talk mic still works.\n\n'
        'Searched:\n${e.searchedPaths.take(6).map((p) => '• $p').join('\n')}',
      );
      rethrow;
    } on SherpaModelMissingException catch (e) {
      await _failBackToDisarmed(
        'VAD model not installed.\n\n'
        'See assets/sherpa/README.md. Tap-to-talk mic still works.\n\n'
        'Searched:\n${e.searchedPaths.take(6).map((p) => '• $p').join('\n')}',
      );
      rethrow;
    } catch (e, st) {
      debugPrint('HandsFreeOrchestrator.arm failed: $e\n$st');
      await _failBackToDisarmed('Failed to arm hands-free: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> disarm() async {
    if (stage == HandsFreeStage.disarmed) return;
    await _teardownArmedResources();
    _resetTurnState();
    _wasThinking = false;
    _setStage(
      HandsFreeStage.disarmed,
      statusLine: HandsFreeSnapshot.disarmed.statusLine,
      clearError: true,
    );
  }

  Future<void> suspendForExternalInference() => disarm();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _teardownArmedResources();
    _vad?.dispose();
    _vad = null;
    if (!_snapshots.isClosed) await _snapshots.close();
  }

  void _onPcmChunk(Uint8List bytes) {
    if (_disposed) return;
    final s = stage;
    if (s == HandsFreeStage.thinking ||
        s == HandsFreeStage.speaking ||
        s == HandsFreeStage.error ||
        s == HandsFreeStage.disarmed ||
        s == HandsFreeStage.booting) {
      return;
    }

    final samples = _pcm16ToFloat32(bytes);
    if (samples.isEmpty) return;

    _pushPreRoll(samples);
    _routeToVad(samples);
  }

  void _routeToVad(Float32List samples) {
    final vad = _vad;
    if (vad == null) return;

    _appendToTurnBuffer(samples);

    final events = vad.feed(samples);
    for (final ev in events) {
      if (ev.kind == VadEventKind.speechStart) {
        if (!_preRollSpliced) {
          _spliceInPreRoll();
        }
      } else if (ev.kind == VadEventKind.speechEnd) {
        _finalizeTurn(ev.samples);
        return;
      }
    }

    if (_turnSamples >= _sampleRate * _turnHardCap.inSeconds) {
      _flushAndSubmitTurn();
    }
  }

  void _appendToTurnBuffer(Float32List samples) {
    _turnBuffer.add(samples);
    _turnSamples += samples.length;
  }

  void _spliceInPreRoll() {
    _preRollSpliced = true;
    if (_preRoll.isEmpty) return;
    final pre = <Float32List>[..._preRoll];
    final preSamples = _preRollSamples;
    _preRoll.clear();
    _preRollSamples = 0;
    _turnBuffer.insertAll(0, pre);
    _turnSamples += preSamples;
  }

  void _pushPreRoll(Float32List samples) {
    _preRoll.add(samples);
    _preRollSamples += samples.length;
    while (_preRollSamples > _preRollCapacity && _preRoll.isNotEmpty) {
      final head = _preRoll.first;
      final excess = _preRollSamples - _preRollCapacity;
      if (excess >= head.length) {
        _preRoll.removeAt(0);
        _preRollSamples -= head.length;
      } else {
        _preRoll[0] = Float32List.fromList(
          head.sublist(excess, head.length),
        );
        _preRollSamples -= excess;
      }
    }
  }

  void _finalizeTurn(Float32List vadSegment) {
    if (_turnFinalized) return;
    _turnFinalized = true;
    _turnHardCapTimer?.cancel();
    _turnHardCapTimer = null;

    Float32List finalSamples = vadSegment;
    if (finalSamples.isEmpty) {
      finalSamples = _flattenTurnBuffer();
    }
    _turnBuffer.clear();
    _turnSamples = 0;

    if (finalSamples.length < _sampleRate ~/ 4) {
      debugPrint(
        'HandsFreeOrchestrator: turn dropped (${finalSamples.length} samples).',
      );
      _backToListening('Listening… (too short — try again)');
      return;
    }

    _setStage(
      HandsFreeStage.thinking,
      statusLine: 'Transcribing…',
      clearError: true,
    );

    final wav = _encodeWav16kMono(finalSamples);
    unawaited(
      _gateway.askBytes(wav).catchError((Object e, StackTrace st) {
        debugPrint('HandsFreeOrchestrator: gateway.askBytes failed: $e\n$st');
        _enterError('Voice loop failed: $e');
      }),
    );
  }

  void _flushAndSubmitTurn() {
    if (stage != HandsFreeStage.listening && stage != HandsFreeStage.thinking) {
      return;
    }
    if (_turnFinalized) return;
    final flushed = _vad?.flush() ?? const <VadEvent>[];
    Float32List segment = Float32List(0);
    for (final ev in flushed) {
      if (ev.kind == VadEventKind.speechEnd && ev.samples.isNotEmpty) {
        segment = ev.samples;
        break;
      }
    }
    _finalizeTurn(segment);
  }

  void _onGatewaySnapshot(GatewaySnapshot s) {
    final wasThinking = _wasThinking;
    _wasThinking = s.isThinking;

    if (s.isTranscribing && stage == HandsFreeStage.thinking) {
      _setStage(
        HandsFreeStage.thinking,
        statusLine: 'Transcribing…',
        clearError: true,
      );
    } else if (s.isThinking && stage == HandsFreeStage.thinking) {
      _setStage(
        HandsFreeStage.thinking,
        statusLine: 'Thinking…',
        clearError: true,
      );
    }

    if (wasThinking && !s.isThinking) {
      if (stage == HandsFreeStage.thinking) {
        _setStage(
          HandsFreeStage.speaking,
          statusLine: 'Speaking…',
          clearError: true,
        );
        _speakingCeilingTimer?.cancel();
        _speakingCeilingTimer = Timer(_speakingCeiling, () {
          if (stage == HandsFreeStage.speaking) {
            unawaited(_tts.stop());
            _backToListening('Listening…');
          }
        });
        unawaited(_playReplyTts());
      }
    }
  }

  String? _lastModelReplyText() {
    final turns = _gateway.current.turns;
    for (var i = turns.length - 1; i >= 0; i--) {
      final t = turns[i];
      if (t.role != TurnRole.model || t.isStreaming) continue;
      final text = t.text.trim();
      if (text.isEmpty) continue;
      if (text.startsWith('(model error')) continue;
      return text;
    }
    return null;
  }

  Future<void> _playReplyTts() async {
    if (stage != HandsFreeStage.speaking) return;
    final text = _lastModelReplyText();
    if (text == null) {
      _backToListening('Listening…');
      return;
    }
    await _pauseMicForTts();
    try {
      final lang = _gateway.lastTurnLanguage ?? 'en';
      final result = await _tts.speakInLanguage(text: text, language: lang);
      if (result.usedEnglishFallback) {
        _gateway.annotateLastModelTurnTtsFallback(
          MultilingualTTS.kTtsFallbackBanner,
        );
      }
    } catch (e, st) {
      debugPrint('HandsFreeOrchestrator: TTS failed: $e\n$st');
      if (stage == HandsFreeStage.speaking) {
        _backToListening('Listening…');
      }
    } finally {
      await _resumeMicIfArmed();
    }
  }

  Future<void> _pauseMicForTts() async {
    if (stage == HandsFreeStage.disarmed || _micPausedForTts) return;
    _micPausedForTts = true;
    await _micSub?.cancel();
    _micSub = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
  }

  Future<void> _resumeMicIfArmed() async {
    if (stage == HandsFreeStage.disarmed) {
      _micPausedForTts = false;
      return;
    }
    if (!_micPausedForTts) return;
    _micPausedForTts = false;
    if (_micSub != null) return;
    try {
      await _startMicStream();
    } catch (e, st) {
      debugPrint('HandsFreeOrchestrator: mic resume failed: $e\n$st');
      _enterError('Microphone failed to restart.');
    }
  }

  Future<void> _startMicStream() async {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
      ),
    );
    _micSub = stream.listen(
      _onPcmChunk,
      onError: (Object e, StackTrace st) {
        debugPrint('HandsFreeOrchestrator mic error: $e\n$st');
      },
      cancelOnError: false,
    );
  }

  void _onUtteranceComplete(void _) {
    if (stage == HandsFreeStage.speaking) {
      _speakingCeilingTimer?.cancel();
      _speakingCeilingTimer = null;
      _backToListening('Listening…');
    }
  }

  void _backToListening(String statusLine) {
    if (_disposed) return;
    _resetTurnState();
    _vad?.reset();
    _setStage(
      HandsFreeStage.listening,
      statusLine: statusLine,
      clearError: true,
    );
    _turnHardCapTimer?.cancel();
    _turnHardCapTimer = Timer(_turnHardCap, _flushAndSubmitTurn);
  }

  void _enterError(String message) {
    if (_disposed) return;
    _resetTurnState();
    _setStage(
      HandsFreeStage.error,
      statusLine: 'Voice loop error — recovering…',
      lastError: message,
    );
    _errorRecoveryTimer?.cancel();
    _errorRecoveryTimer = Timer(_errorRecovery, () {
      if (stage == HandsFreeStage.error) {
        _backToListening('Listening…');
      }
    });
  }

  Future<void> _failBackToDisarmed(String message) async {
    await _teardownArmedResources();
    _resetTurnState();
    _setStage(
      HandsFreeStage.disarmed,
      statusLine: HandsFreeSnapshot.disarmed.statusLine,
      lastError: message,
    );
  }

  Future<void> _teardownArmedResources() async {
    _turnHardCapTimer?.cancel();
    _turnHardCapTimer = null;
    _errorRecoveryTimer?.cancel();
    _errorRecoveryTimer = null;
    _speakingCeilingTimer?.cancel();
    _speakingCeilingTimer = null;

    await _micSub?.cancel();
    _micSub = null;
    await _gatewaySub?.cancel();
    _gatewaySub = null;
    await _synthSub?.cancel();
    _synthSub = null;

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}

    _vad?.reset();
    _micPausedForTts = false;
  }

  void _resetTurnState() {
    _preRoll.clear();
    _preRollSamples = 0;
    _turnBuffer.clear();
    _turnSamples = 0;
    _preRollSpliced = false;
    _turnFinalized = false;
  }

  void _setStage(
    HandsFreeStage s, {
    required String statusLine,
    String? lastError,
    bool clearError = false,
  }) {
    _snap = _snap.copyWith(
      stage: s,
      statusLine: statusLine,
      lastError: lastError,
      clearError: clearError && lastError == null,
    );
    if (!_snapshots.isClosed) {
      _snapshots.add(_snap);
    }
  }

  Float32List _flattenTurnBuffer() {
    if (_turnBuffer.isEmpty) return Float32List(0);
    final out = Float32List(_turnSamples);
    int off = 0;
    for (final c in _turnBuffer) {
      out.setRange(off, off + c.length, c);
      off += c.length;
    }
    return out;
  }

  Float32List _pcm16ToFloat32(Uint8List bytes) {
    final usable = bytes.length - (bytes.length % 2);
    if (usable <= 0) return Float32List(0);
    final values = Float32List(usable >> 1);
    final view = ByteData.sublistView(bytes, 0, usable);
    for (int i = 0; i < values.length; i++) {
      final s = view.getInt16(i * 2, Endian.little);
      values[i] = s / 32768.0;
    }
    return values;
  }

  Uint8List _encodeWav16kMono(Float32List samples) {
    final pcmLength = samples.length * 2;
    final buffer = BytesBuilder();
    void writeStr(String s) =>
        buffer.add(Uint8List.fromList(s.codeUnits));
    void writeU32(int v) {
      final b = ByteData(4)..setUint32(0, v, Endian.little);
      buffer.add(b.buffer.asUint8List());
    }

    void writeU16(int v) {
      final b = ByteData(2)..setUint16(0, v, Endian.little);
      buffer.add(b.buffer.asUint8List());
    }

    writeStr('RIFF');
    writeU32(36 + pcmLength);
    writeStr('WAVE');
    writeStr('fmt ');
    writeU32(16);
    writeU16(1);
    writeU16(1);
    writeU32(_sampleRate);
    writeU32(_sampleRate * 2);
    writeU16(2);
    writeU16(16);
    writeStr('data');
    writeU32(pcmLength);

    final pcm = ByteData(pcmLength);
    for (int i = 0; i < samples.length; i++) {
      double v = samples[i];
      if (v > 1.0) v = 1.0;
      if (v < -1.0) v = -1.0;
      pcm.setInt16(i * 2, (v * 32767).round(), Endian.little);
    }
    buffer.add(pcm.buffer.asUint8List());
    return buffer.toBytes();
  }
}
