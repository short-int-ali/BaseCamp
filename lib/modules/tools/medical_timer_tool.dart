import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import 'tool_beep_player.dart';
import 'tool_call.dart';
import 'tool_dispatcher.dart';
import 'tool_invocation.dart';

/// Labelled, alerting timer for time-critical first-aid checkpoints.
///
/// Three [kind]s, all sharing the same execution path:
///
/// - `tourniquet` — defaults `alert_minutes` to `[60, 120]`. The 120 min
///   alert is the conventional "consider conversion" / "permanent
///   ischemic damage likely" boundary. Tray card flips red after 60 min
///   and pulses red after 120 min.
/// - `checkup` — generic re-assessment timer. Defaults to a single
///   `[15]` alert (typical bleeding-control re-check interval).
/// - `generic` — model-supplied label and alert schedule with no
///   defaults.
///
/// Multiple timers can run concurrently — see
/// [ToolDispatcher._concurrentNames]. The responder may have a left-leg
/// tourniquet timer at 1h2m AND a re-assess timer at 4m simultaneously.
class MedicalTimerTool implements ToolHandler {
  MedicalTimerTool();

  @override
  String get name => 'medical_timer';

  final Map<String, _TimerRun> _runs = <String, _TimerRun>{};

  @override
  String labelFor(ToolCall call) {
    final kind = _kindArg(call.args['kind']);
    final label = _labelArg(call.args['label']);
    if (label == null) {
      switch (kind) {
        case 'tourniquet':
          return 'Tourniquet timer';
        case 'checkup':
          return 'Checkup timer';
        case 'generic':
        default:
          return 'Timer';
      }
    }
    return label;
  }

  @override
  Future<void> start(
    ToolInvocation invocation,
    void Function() onUpdate,
  ) async {
    final args = invocation.call.args;
    final kind = _kindArg(args['kind']);
    final alerts = _alertMinutesArg(args['alert_minutes'], kind: kind);

    invocation.label = labelFor(invocation.call);
    invocation.kind = kind;
    invocation.payload = <String, Object?>{
      'kind': kind,
      'alerts_minutes': alerts,
      'alerts_fired': <int>[],
    };
    // We do NOT set etaSec — these timers are open-ended; the UI
    // shows a count-up. The alerts are the meaningful checkpoints.
    invocation.status = ToolStatus.running;
    onUpdate();

    unawaited(ToolBeepPlayer.instance.ensureCprReady());

    final run = _TimerRun(alerts: alerts);
    _runs[invocation.id] = run;

    // Schedule each alert as its own one-shot Timer so the firing is
    // robust against drift (a single periodic timer would compound
    // skew across long-running tourniquet windows). Cap individual
    // delays at 4h to keep the Timer queue bounded; anything past
    // that is well outside actionable first-aid territory.
    for (final m in alerts) {
      final delay = Duration(minutes: m);
      if (delay.inMinutes > 4 * 60) continue;
      run.timers.add(Timer(delay, () {
        if (!_runs.containsKey(invocation.id)) return;
        _fireAlert(invocation, m, onUpdate);
      }));
    }
  }

  @override
  Future<void> stop(ToolInvocation invocation) async {
    final run = _runs.remove(invocation.id);
    run?.cancel();
    await ToolBeepPlayer.instance.stop();
    if (invocation.status != ToolStatus.cancelled &&
        invocation.status != ToolStatus.completed) {
      invocation.status = ToolStatus.cancelled;
    }
  }

  void _fireAlert(
    ToolInvocation invocation,
    int minute,
    void Function() onUpdate,
  ) {
    final payload = invocation.payload;
    if (payload != null) {
      final fired = (payload['alerts_fired'] as List<dynamic>? ?? <int>[])
          .cast<int>();
      if (!fired.contains(minute)) {
        fired.add(minute);
        payload['alerts_fired'] = fired;
      }
    }
    invocation.lastAlertAt = DateTime.now();
    unawaited(_alertHaptic());
    // #region agent log
    debugPrint('[DBG-b37fdb] H1 MedicalTimer._fireAlert: minute=$minute, firing beep');
    // #endregion
    ToolBeepPlayer.instance.playCprBeat();
    onUpdate();
  }

  Future<void> _alertHaptic() async {
    if (Platform.isAndroid) {
      try {
        final has = await Vibration.hasVibrator();
        if (has == true) {
          await Vibration.vibrate(
            pattern: const <int>[0, 200, 120, 200, 120, 200],
            intensities: const <int>[0, 255, 0, 255, 0, 255],
          );
          return;
        }
      } catch (e) {
        debugPrint('MedicalTimerTool: alert vibrate failed: $e');
      }
    }
    // iOS fallback: three discrete impacts spaced ~120 ms apart.
    for (var i = 0; i < 3; i++) {
      unawaited(HapticFeedback.heavyImpact());
      await Future<void>.delayed(const Duration(milliseconds: 320));
    }
  }

  // ------------------------------------------------------------------
  // Arg parsing
  // ------------------------------------------------------------------

  static String _kindArg(Object? raw) {
    if (raw is! String) return 'generic';
    final v = raw.trim().toLowerCase();
    if (v == 'tourniquet' || v == 'checkup' || v == 'generic') return v;
    if (v.startsWith('tourn')) return 'tourniquet';
    if (v.startsWith('check') || v.startsWith('reassess')) return 'checkup';
    return 'generic';
  }

  static String? _labelArg(Object? raw) {
    if (raw is! String) return null;
    final v = raw.trim();
    if (v.isEmpty) return null;
    return v.length > 64 ? v.substring(0, 64) : v;
  }

  static List<int> _alertMinutesArg(Object? raw, {required String kind}) {
    final defaults = _defaultAlertsFor(kind);
    if (raw is! List) return defaults;

    final out = <int>[];
    for (final v in raw) {
      int? minute;
      if (v is num) {
        minute = v.round();
      } else if (v is String) {
        minute = int.tryParse(v.trim());
      }
      if (minute == null) continue;
      if (minute <= 0 || minute > 6 * 60) continue;
      if (!out.contains(minute)) out.add(minute);
    }
    if (out.isEmpty) return defaults;
    out.sort();
    return out;
  }

  static List<int> _defaultAlertsFor(String kind) {
    switch (kind) {
      case 'tourniquet':
        return const <int>[60, 120];
      case 'checkup':
        return const <int>[15];
      case 'generic':
      default:
        return const <int>[];
    }
  }
}

class _TimerRun {
  _TimerRun({required this.alerts});

  final List<int> alerts;
  final List<Timer> timers = <Timer>[];

  void cancel() {
    for (final t in timers) {
      t.cancel();
    }
    timers.clear();
  }
}
