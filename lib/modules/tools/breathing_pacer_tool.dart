import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import 'tool_beep_player.dart';
import 'tool_call.dart';
import 'tool_dispatcher.dart';
import 'tool_invocation.dart';

/// Phase of the breathing pacer state machine. The UI overlay reads
/// these via [ToolInvocation.payload] and animates an expanding /
/// contracting / steady ring per phase.
enum BreathPhase { inhale, holdAfterInhale, exhale, holdAfterExhale }

extension BreathPhaseLabel on BreathPhase {
  String get label {
    switch (this) {
      case BreathPhase.inhale:
        return 'Breathe in';
      case BreathPhase.holdAfterInhale:
        return 'Hold';
      case BreathPhase.exhale:
        return 'Breathe out';
      case BreathPhase.holdAfterExhale:
        return 'Hold';
    }
  }
}

/// Phase-paced breathing exercise for panic / hyperventilation.
///
/// Two patterns supported:
///
/// - `box`: 4-4-4-4 (inhale, hold, exhale, hold). Standard tactical
///   breathing; safe for most panic-attack contexts.
/// - `4-7-8`: 4-7-8 (Dr. Andrew Weil's relaxing breath; we encode the
///   trailing hold as 0 s). Stronger parasympathetic effect; better
///   for severe panic but requires the patient is not actively
///   hyperventilating.
///
/// On every phase boundary we fire a single short haptic (different
/// intensity per phase so the patient can feel the transition without
/// looking at the screen) and update [ToolInvocation.payload] with
/// the current phase, cycle index, and remaining seconds in this
/// phase. The UI overlay subscribes to the dispatcher's invocation
/// stream and renders accordingly.
class BreathingPacerTool implements ToolHandler {
  BreathingPacerTool();

  @override
  String get name => 'breathing_pacer';

  final Map<String, _PacerRun> _runs = <String, _PacerRun>{};

  @override
  String labelFor(ToolCall call) {
    final patternName = _patternName(call.args['pattern']);
    final cycles = _intArg(call.args, 'cycles',
        defaultValue: 5, min: 1, max: 12);
    return 'Breathing · $patternName · $cycles cycles';
  }

  @override
  Future<void> start(
    ToolInvocation invocation,
    void Function() onUpdate,
  ) async {
    final args = invocation.call.args;
    final pattern = _patternName(args['pattern']);
    final cycles =
        _intArg(args, 'cycles', defaultValue: 5, min: 1, max: 12);
    final durations = _phaseDurations(pattern);

    invocation.label = labelFor(invocation.call);
    invocation.kind = pattern;
    invocation.payload = <String, Object?>{
      'pattern': pattern,
      'cycles_total': cycles,
      'cycles_done': 0,
      'phase': BreathPhase.inhale.name,
      'phase_label': BreathPhase.inhale.label,
      'phase_total_ms': durations[0].inMilliseconds,
      'phase_started_at_ms': DateTime.now().millisecondsSinceEpoch,
    };
    invocation.status = ToolStatus.running;
    invocation.etaSec = Duration(
      seconds: cycles *
          ((durations[0] +
                      durations[1] +
                      durations[2] +
                      durations[3])
                  .inSeconds),
    );
    onUpdate();

    final run = _PacerRun();
    _runs[invocation.id] = run;

    // Phase 0 starts now — fire the boundary haptic for it. We do not
    // await `_haptic` so a slow vibration call cannot delay the first
    // phase tick.
    unawaited(_haptic(BreathPhase.inhale));
    ToolBeepPlayer.instance.playBreathCueNamed(BreathPhase.inhale.name);

    run.timer = _scheduleNext(
      invocation,
      onUpdate,
      run,
      cycles: cycles,
      durations: durations,
      cycleIdx: 0,
      phaseIdx: 0,
    );
  }

  Timer _scheduleNext(
    ToolInvocation invocation,
    void Function() onUpdate,
    _PacerRun run, {
    required int cycles,
    required List<Duration> durations,
    required int cycleIdx,
    required int phaseIdx,
  }) {
    return Timer(durations[phaseIdx], () {
      if (!_runs.containsKey(invocation.id)) return;

      var nextPhase = phaseIdx + 1;
      var nextCycle = cycleIdx;
      if (nextPhase >= 4) {
        nextPhase = 0;
        nextCycle = cycleIdx + 1;
      }

      if (nextCycle >= cycles) {
        // Final hold finished — finish the exercise.
        unawaited(_finish(invocation, ToolStatus.completed, onUpdate));
        return;
      }

      final phase = BreathPhase.values[nextPhase];
      final payload = invocation.payload;
      if (payload != null) {
        payload['cycles_done'] = nextCycle;
        payload['phase'] = phase.name;
        payload['phase_label'] = phase.label;
        payload['phase_total_ms'] = durations[nextPhase].inMilliseconds;
        payload['phase_started_at_ms'] =
            DateTime.now().millisecondsSinceEpoch;
      }
      unawaited(_haptic(phase));
      ToolBeepPlayer.instance.playBreathCueNamed(phase.name);
      onUpdate();

      run.timer = _scheduleNext(
        invocation,
        onUpdate,
        run,
        cycles: cycles,
        durations: durations,
        cycleIdx: nextCycle,
        phaseIdx: nextPhase,
      );
    });
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
    if (invocation.status != ToolStatus.cancelled &&
        invocation.status != ToolStatus.completed) {
      invocation.status = terminal;
    }
    onUpdate?.call();
  }

  /// Per-phase haptic. We bias the vibrator harder for inhale/exhale
  /// (motion) than for holds (stillness) so the patient can feel the
  /// transitions without watching the ring.
  Future<void> _haptic(BreathPhase phase) async {
    final isMotion = phase == BreathPhase.inhale || phase == BreathPhase.exhale;

    if (Platform.isAndroid) {
      try {
        final has = await Vibration.hasVibrator();
        if (has == true) {
          await Vibration.vibrate(
            duration: isMotion ? 90 : 40,
            amplitude: isMotion ? 200 : 120,
          );
          return;
        }
      } catch (e) {
        debugPrint('BreathingPacerTool: vibrate failed: $e');
      }
    }
    // iOS / no vibrator — rely on the built-in haptic engine.
    if (isMotion) {
      await HapticFeedback.mediumImpact();
    } else {
      await HapticFeedback.selectionClick();
    }
  }

  // ------------------------------------------------------------------
  // Arg parsing
  // ------------------------------------------------------------------

  static String _patternName(Object? raw) {
    if (raw is! String) return 'box';
    final v = raw.trim().toLowerCase();
    if (v.isEmpty) return 'box';
    if (v.startsWith('4-7-8') || v.contains('478') || v == '4 7 8') {
      return '4-7-8';
    }
    return 'box';
  }

  /// Returns `[inhale, holdAfterInhale, exhale, holdAfterExhale]`
  /// durations for the named pattern.
  static List<Duration> _phaseDurations(String pattern) {
    switch (pattern) {
      case '4-7-8':
        return const <Duration>[
          Duration(seconds: 4),
          Duration(seconds: 7),
          Duration(seconds: 8),
          Duration(seconds: 0),
        ];
      case 'box':
      default:
        return const <Duration>[
          Duration(seconds: 4),
          Duration(seconds: 4),
          Duration(seconds: 4),
          Duration(seconds: 4),
        ];
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
}

class _PacerRun {
  Timer? timer;

  void cancel() {
    timer?.cancel();
    timer = null;
  }
}
