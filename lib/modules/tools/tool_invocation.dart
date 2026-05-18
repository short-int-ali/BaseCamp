import 'tool_call.dart';

/// Lifecycle status of a [ToolInvocation].
enum ToolStatus {
  /// Accepted by the dispatcher, side-effect has not started yet.
  pending,

  /// Side-effect (vibration / pacer / timer) is currently active.
  running,

  /// Finished cleanly under its own steam (e.g. breathing pacer
  /// completed all its cycles).
  completed,

  /// Cancelled by the user (STOP button) or by the gateway (reset /
  /// suspendForExternalInference).
  cancelled,

  /// Tool handler threw or rejected the args. The invocation card in
  /// the tray renders [errorMessage] instead of an elapsed counter.
  error,
}

/// Live, mutable state of one tool that has been (or is about to be)
/// run. The dispatcher mutates these and re-broadcasts the full list
/// on every change so the UI tray can render with no extra plumbing.
class ToolInvocation {
  ToolInvocation({
    required this.call,
    required this.label,
    required this.status,
    required this.startedAt,
    this.kind,
    this.etaSec,
    this.lastAlertAt,
    this.errorMessage,
    this.payload,
  });

  /// The original [ToolCall] this invocation was opened from. We keep
  /// it so the UI can still display original args (e.g. BPM) and so
  /// the gateway can correlate streaming-time tag ids with the rendered
  /// tray entries.
  final ToolCall call;

  /// Short human-readable label rendered in the tray card. The tool
  /// itself sets this from the (possibly defaulted) args — e.g. for
  /// CPR cadence: "Adult CPR · 110 BPM".
  String label;

  /// Optional sub-kind identifier used by tools that expose multiple
  /// variants (currently only `medical_timer` with `tourniquet` /
  /// `checkup` / `generic`). Lets the UI tint and badge the card per
  /// variant without bolting another concrete type on top of
  /// [ToolInvocation].
  String? kind;

  ToolStatus status;

  /// Wall-clock instant the invocation transitioned to [ToolStatus.running].
  /// Used by the UI's elapsed counter; not adjusted on cancel.
  final DateTime startedAt;

  /// For tools with a known finite duration (breathing pacer cycles,
  /// CPR cadence with explicit `duration_sec`). Null for open-ended
  /// timers. Tray cards switch from a count-up to a count-down display
  /// when this is set.
  Duration? etaSec;

  /// Last time an alert haptic fired. Drives the "alert flash" red
  /// bar on the tray card for ~3 s after each alert without forcing
  /// the tool to keep emitting state changes.
  DateTime? lastAlertAt;

  /// Populated when [status] is [ToolStatus.error].
  String? errorMessage;

  /// Free-form per-tool data the UI may need (e.g. current breathing
  /// phase for the pacer overlay). Tools that don't need this leave it
  /// null; cards check for the keys they care about.
  Map<String, Object?>? payload;

  String get id => call.id;
  String get name => call.name;

  /// Wall-clock elapsed since [startedAt]. The UI re-reads this on a
  /// 250 ms tick rather than waiting for tool-side state changes, so
  /// the count keeps moving even when nothing else is happening.
  Duration get elapsed => DateTime.now().difference(startedAt);

  bool get isActive =>
      status == ToolStatus.pending || status == ToolStatus.running;
}
