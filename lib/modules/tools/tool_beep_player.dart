import 'dart:async' show Completer, unawaited;
import 'dart:io';
import 'dart:math' show pi, sin;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

/// Low-latency metronome / phase cues for agentic tools (CPR, breathing).
///
/// Uses [AudioPool] with on-disk WAV cues so beats stay audible on Android
/// even when the mic or TTS holds audio focus (transient ducking).
class ToolBeepPlayer {
  ToolBeepPlayer._();

  static final ToolBeepPlayer instance = ToolBeepPlayer._();

  static const _cprKey = 'cpr_1000';
  static const _inhaleKey = 'inhale_880';
  static const _exhaleKey = 'exhale_660';
  static const _holdKey = 'hold_520';

  final Map<String, String> _paths = <String, String>{};
  AudioPool? _cprPool;
  AudioPool? _inhalePool;
  AudioPool? _exhalePool;
  AudioPool? _holdPool;
  bool _contextApplied = false;

  static AudioContext get _audioContext => AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {
            AVAudioSessionOptions.mixWithOthers,
            AVAudioSessionOptions.duckOthers,
          },
        ),
      );

  /// Pre-warm CPR metronome pool (call when CPR tool starts).
  Future<void> ensureCprReady() async {
    // #region agent log
    debugPrint('[DBG-b37fdb] H2 ensureCprReady CALLED, _cprPool=${_cprPool != null}');
    // #endregion
    await _ensurePool(
      poolRef: () => _cprPool,
      setPool: (p) => _cprPool = p,
      fileKey: _cprKey,
      frequencyHz: 1000,
      durationMs: 85,
      amplitude: 0.98,
    );
    // #region agent log
    debugPrint('[DBG-b37fdb] H2 ensureCprReady DONE, _cprPool=${_cprPool != null}');
    // #endregion
  }

  /// Diagnostic: play a tone using a plain AudioPlayer (mediaPlayer mode,
  /// music stream) to isolate SoundPool vs MediaPlayer and sonification
  /// vs media stream issues.
  Future<void> diagnosticPlay() async {
    try {
      final path = await _tonePath(
        _cprKey,
        frequencyHz: 1000,
        durationMs: 300,
        amplitude: 0.98,
      );
      final file = File(path);
      final exists = await file.exists();
      final bytes = exists ? await file.length() : 0;
      debugPrint('[DBG-b37fdb] H7 diagnosticPlay: file=$path exists=$exists bytes=$bytes');

      final player = AudioPlayer();
      await player.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {AVAudioSessionOptions.mixWithOthers},
        ),
      ));
      await player.setPlayerMode(PlayerMode.mediaPlayer);
      await player.setVolume(1.0);
      await player.setSourceDeviceFile(path);
      debugPrint('[DBG-b37fdb] H5H6 diagnosticPlay: source set, calling play (mediaPlayer + music stream)');

      final done = Completer<void>();
      player.onPlayerComplete.listen((_) {
        debugPrint('[DBG-b37fdb] H5H6 diagnosticPlay: playback COMPLETE');
        if (!done.isCompleted) done.complete();
      });
      player.onPlayerStateChanged.listen((s) {
        debugPrint('[DBG-b37fdb] H5H6 diagnosticPlay: state=$s');
      });

      await player.resume();
      debugPrint('[DBG-b37fdb] H5H6 diagnosticPlay: resume() returned');
      await done.future.timeout(const Duration(seconds: 3), onTimeout: () {
        debugPrint('[DBG-b37fdb] H5H6 diagnosticPlay: TIMEOUT — no completion in 3s');
      });
      await player.dispose();
    } catch (e) {
      debugPrint('[DBG-b37fdb] H5H6 diagnosticPlay EXCEPTION: $e');
    }
  }

  /// CPR compression beat — fire-and-forget.
  void playCprBeat() {
    unawaited(_playPool(() => _cprPool, ensureCprReady));
  }

  /// Phase boundary cue for [BreathingPacerTool] (`phase.name`).
  void playBreathCueNamed(String phaseName) {
    unawaited(_playBreathCueAsync(phaseName));
  }

  Future<void> _playBreathCueAsync(String phaseName) async {
    try {
      switch (phaseName) {
        case 'inhale':
          await _ensurePool(
            poolRef: () => _inhalePool,
            setPool: (p) => _inhalePool = p,
            fileKey: _inhaleKey,
            frequencyHz: 880,
            durationMs: 110,
            amplitude: 0.9,
          );
          await _playPool(() => _inhalePool, () async {});
        case 'exhale':
          await _ensurePool(
            poolRef: () => _exhalePool,
            setPool: (p) => _exhalePool = p,
            fileKey: _exhaleKey,
            frequencyHz: 660,
            durationMs: 110,
            amplitude: 0.88,
          );
          await _playPool(() => _exhalePool, () async {});
        case 'holdAfterInhale':
        case 'holdAfterExhale':
          await _ensurePool(
            poolRef: () => _holdPool,
            setPool: (p) => _holdPool = p,
            fileKey: _holdKey,
            frequencyHz: 520,
            durationMs: 55,
            amplitude: 0.55,
          );
          await _playPool(() => _holdPool, () async {});
      }
    } catch (e) {
      debugPrint('ToolBeepPlayer: breath cue failed: $e');
    }
  }

  Future<void> stop() async {
    await _disposePool(_cprPool);
    _cprPool = null;
    await _disposePool(_inhalePool);
    _inhalePool = null;
    await _disposePool(_exhalePool);
    _exhalePool = null;
    await _disposePool(_holdPool);
    _holdPool = null;
  }

  Future<void> _playPool(
    AudioPool? Function() poolGetter,
    Future<void> Function() ensure,
  ) async {
    try {
      await ensure();
      final p = poolGetter();
      // #region agent log
      debugPrint('[DBG-b37fdb] H2 _playPool: pool=${p != null}');
      // #endregion
      if (p == null) return;
      await p.start(volume: 1.0);
      // #region agent log
      debugPrint('[DBG-b37fdb] H2 _playPool: start() returned OK');
      // #endregion
    } catch (e) {
      // #region agent log
      debugPrint('[DBG-b37fdb] H2 _playPool EXCEPTION: $e');
      // #endregion
      debugPrint('ToolBeepPlayer: play failed: $e');
    }
  }

  Future<void> _ensurePool({
    required AudioPool? Function() poolRef,
    required void Function(AudioPool?) setPool,
    required String fileKey,
    required double frequencyHz,
    required int durationMs,
    required double amplitude,
  }) async {
    if (poolRef() != null) return;

    if (!_contextApplied) {
      try {
        await AudioPlayer.global.setAudioContext(_audioContext);
        _contextApplied = true;
      } catch (e) {
        debugPrint('ToolBeepPlayer: setAudioContext failed: $e');
      }
    }

    final path = await _tonePath(
      fileKey,
      frequencyHz: frequencyHz,
      durationMs: durationMs,
      amplitude: amplitude,
    );

    // #region agent log
    debugPrint('[DBG-b37fdb] H2 _ensurePool: creating AudioPool for $fileKey path=$path');
    // #endregion
    try {
      final pool = await AudioPool.create(
        source: DeviceFileSource(path),
        minPlayers: 2,
        maxPlayers: 4,
        playerMode: PlayerMode.mediaPlayer,
        audioContext: _audioContext,
      );
      setPool(pool);
      // #region agent log
      debugPrint('[DBG-b37fdb] H2 _ensurePool: AudioPool created OK for $fileKey');
      // #endregion
    } catch (e) {
      // #region agent log
      debugPrint('[DBG-b37fdb] H2 _ensurePool POOL CREATE FAILED: $e');
      // #endregion
      rethrow;
    }
  }

  Future<String> _tonePath(
    String key, {
    required double frequencyHz,
    required int durationMs,
    required double amplitude,
  }) async {
    final cached = _paths[key];
    if (cached != null) return cached;

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/basecamp_beep_$key.wav';
    final file = File(path);
    if (!await file.exists()) {
      await file.writeAsBytes(
        _generateToneWav(
          frequencyHz: frequencyHz,
          durationMs: durationMs,
          amplitude: amplitude,
        ),
        flush: true,
      );
    }
    _paths[key] = path;
    return path;
  }

  Future<void> _disposePool(AudioPool? pool) async {
    if (pool == null) return;
    try {
      await pool.dispose();
    } catch (e) {
      debugPrint('ToolBeepPlayer: pool dispose failed: $e');
    }
  }

  /// Mono 16-bit PCM WAV at 44.1 kHz with a short attack/decay envelope.
  static Uint8List _generateToneWav({
    required double frequencyHz,
    required int durationMs,
    required double amplitude,
    int sampleRate = 44100,
  }) {
    final numSamples = (sampleRate * durationMs) ~/ 1000;
    final pcmLength = numSamples * 2;
    final pcm = ByteData(pcmLength);
    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final attack = numSamples * 0.08;
      final release = numSamples * 0.25;
      double env = 1.0;
      if (i < attack) {
        env = i / attack;
      } else if (i > numSamples - release) {
        env = (numSamples - i) / release;
      }
      final sample = sin(2 * pi * frequencyHz * t) * amplitude * env;
      final clipped = sample.clamp(-1.0, 1.0);
      pcm.setInt16(
        i * 2,
        (clipped * 32767).round(),
        Endian.little,
      );
    }

    final buffer = BytesBuilder();
    void writeStr(String s) => buffer.add(Uint8List.fromList(s.codeUnits));
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
    writeU32(sampleRate);
    writeU32(sampleRate * 2);
    writeU16(2);
    writeU16(16);
    writeStr('data');
    writeU32(pcmLength);
    buffer.add(pcm.buffer.asUint8List());
    return buffer.toBytes();
  }
}
