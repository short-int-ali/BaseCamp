import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import 'tool_beep_player.dart';
import 'tool_call.dart';
import 'tool_dispatcher.dart';
import 'tool_invocation.dart';

/// CPR metronome via the phone vibrator.
///
/// AHA / ERC / Canadian Red Cross consensus: 100–120 compressions per
/// minute for adult, child, and infant CPR. We default to 110 BPM
/// (mid-range), clamp the model's `bpm` arg into 90..120 so a
/// hallucinated 60 doesn't cripple the rate, and cap `duration_sec`
/// at 30 minutes (anything longer is almost certainly a bug; a
/// responder doing actual long CPR will re-dispatch the tool).
///
/// Implementation notes:
///
/// - Android: we emit a `Vibration.vibrate(pattern: ..., repeat: 0)`
///   that loops at the OS level — once started, the vibrator runs
///   without further work from Flutter, which is what we want during
///   actual chest compressions (the responder will not be looking at
///   the screen). We re-issue the pattern every 5 s anyway, as a
///   cheap watchdog: some OEMs (Xiaomi MIUI, BBK ColorOS) silently
///   stop the vibrator after ~30 s if the screen turns off.
/// - iOS: `HapticFeedback.heavyImpact()` per beat from a
///   `Timer.periodic`. CoreHaptics could do better but the fallback
///   is intentionally simple for the first pass.
/// - Both platforms: we publish a `tickSeq` int into
///   [ToolInvocation.payload] on every beat so a UI overlay can
///   pulse-animate in lock-step with the haptic.
class CprCadenceTool implements ToolHandler {
  CprCadenceTool();

  @override
  String get name => 'cpr_cadence';

  /// Active state per invocation id. Lets us stop the right vibrator
  /// loop when the dispatcher hands us a stop request that does not
  /// carry the original timers.
  final Map<String, _CprRun> _runs = <String, _CprRun>{};

  @override
  String labelFor(ToolCall call) {
    final bpm = _intArg(call.args, 'bpm', defaultValue: 110, min: 90, max: 120);
    final patient = _patientLabel(call.args['label']);
    return '$patient CPR · $bpm BPM';
  }

  @override
  Future<void> start(
    ToolInvocation invocation,
    void Function() onUpdate,
  ) async {
    final args = invocation.call.args;
    final bpm = _intArg(args, 'bpm', defaultValue: 110, min: 90, max: 120);
    final durationSec = _intArg(
      args,
      'duration_sec',
      defaultValue: 0, // 0 → open-ended
      min: 0,
      max: 30 * 60,
    );

    invocation.label = labelFor(invocation.call);
    invocation.payload = <String, Object?>{
      'bpm': bpm,
      'beat_interval_ms': (60000 / bpm).round(),
      'tick_seq': 0,
    };
    if (durationSec > 0) {
      invocation.etaSec = Duration(seconds: durationSec);
    }
    invocation.status = ToolStatus.running;
    onUpdate();

    unawaited(ToolBeepPlayer.instance.ensureCprReady());

    final beatIntervalMs = (60000 / bpm).round();
    final pulseMs = beatIntervalMs < 200 ? 60 : 80; // tactile but not mushy
    final gapMs = (beatIntervalMs - pulseMs).clamp(20, 60000);

    final useNativePattern = await _supportsNativePattern();
    final run = _CprRun();
    _runs[invocation.id] = run;

    if (useNativePattern) {
      // OS-level repeating pattern: [waitBefore, pulse, waitAfter, pulse, ...]
      // `repeat: 0` rewinds to index 0 of the pattern when it ends.
      final pattern = <int>[0, pulseMs, gapMs, pulseMs];
      try {
        await Vibration.vibrate(
          pattern: pattern,
          intensities: const <int>[0, 220, 0, 220],
          repeat: 0,
        );
      } catch (e) {
        debugPrint('CprCadenceTool: native pattern start failed: $e');
        // Fall through to the timer-driven fallback.
      }

      // Watchdog: re-issue the pattern every ~5 s in case the OEM
      // throttle stops it. Also drives the `tick_seq` payload so the
      // UI animates in step.
      run.watchdog = Timer.periodic(
        Duration(milliseconds: beatIntervalMs),
        (_) async {
          if (!_runs.containsKey(invocation.id)) return;
          ToolBeepPlayer.instance.playCprBeat();
          final payload = invocation.payload;
          if (payload != null) {
            final seq = (payload['tick_seq'] as int? ?? 0) + 1;
            payload['tick_seq'] = seq;
            // Every ~25 beats (~13 s @ 110 BPM) re-prime the pattern.
            if (seq % 25 == 0) {
              try {
                await Vibration.vibrate(
                  pattern: pattern,
                  intensities: const <int>[0, 220, 0, 220],
                  repeat: 0,
                );
              } catch (_) {
                // best-effort
              }
            }
          }
          onUpdate();
        },
      );
    } else {
      // iOS / no native pattern support: hand-rolled metronome.
      run.beatTimer = Timer.periodic(
        Duration(milliseconds: beatIntervalMs),
        (_) {
          if (!_runs.containsKey(invocation.id)) return;
          ToolBeepPlayer.instance.playCprBeat();
          unawaited(HapticFeedback.heavyImpact());
          final payload = invocation.payload;
          if (payload != null) {
            payload['tick_seq'] =
                (payload['tick_seq'] as int? ?? 0) + 1;
          }
          onUpdate();
        },
      );
    }

    if (durationSec > 0) {
      run.durationTimer = Timer(Duration(seconds: durationSec), () {
        if (!_runs.containsKey(invocation.id)) return;
        unawaited(_finish(invocation, ToolStatus.completed, onUpdate));
      });
    }
  }

  @override
  Future<void> stop(ToolInvocation invocation) async {
    await _finish(invocation, ToolStatus.cancelled, null);
  }

  Future<void> _finish(
    ToolInvocation invocation,
    ToolStatus terminal,
    void Function()? onUpdate,
  ) async {
    final run = _runs.remove(invocation.id);
    run?.cancel();
    await ToolBeepPlayer.instance.stop();
    try {
      await Vibration.cancel();
    } catch (_) {
      // best-effort — `cancel` may throw on engines that never started.
    }
    if (invocation.status != ToolStatus.cancelled &&
        invocation.status != ToolStatus.completed) {
      invocation.status = terminal;
    }
    onUpdate?.call();
  }

  Future<bool> _supportsNativePattern() async {
    if (!Platform.isAndroid) return false;
    try {
      final hasIt = await Vibration.hasVibrator();
      return hasIt == true;
    } catch (_) {
      return false;
    }
  }

  static int _intArg(
    Map<String, Object?> args,
    String key, {
    required int defaultValue,
    required int min,
    required int max,
  }) {
    final v = args[key];
    if (v is num) return v.round().clamp(min, max);
    if (v is String) {
      final parsed = int.tryParse(v);
      if (parsed != null) return parsed.clamp(min, max);
    }
    return defaultValue;
  }

  static String _patientLabel(Object? raw) {
    if (raw is! String) return 'Adult';
    final v = raw.trim().toLowerCase();
    if (v.isEmpty) return 'Adult';
    if (v.startsWith('inf')) return 'Infant';
    if (v.startsWith('chi')) return 'Child';
    if (v.startsWith('adu')) return 'Adult';
    return raw.length > 24 ? raw.substring(0, 24) : raw;
  }
}

class _CprRun {
  Timer? watchdog;
  Timer? beatTimer;
  Timer? durationTimer;

  void cancel() {
    watchdog?.cancel();
    watchdog = null;
    beatTimer?.cancel();
    beatTimer = null;
    durationTimer?.cancel();
    durationTimer = null;
  }
}
