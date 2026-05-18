/// Lifecycle stage of the hands-free conversation loop.
///
/// The state machine is single-threaded and lives in
/// [HandsFreeOrchestrator]. Transitions are driven by:
///   * user gestures        (`arm()` / `disarm()`)
///   * VAD events           (speech-start / speech-end after silence)
///   * gateway snapshots    (Whisper + Gemma streaming reply done)
///   * TTS completions      (`MultilingualTTS.utteranceCompletions`)
enum HandsFreeStage {
  /// Hands-free is OFF. Recorder stopped, models idle.
  disarmed,

  /// Loading sherpa VAD + Whisper model. Brief spinner.
  booting,

  /// Mic open, VAD listening for speech. Silence ≥ [kSilenceTriggerSeconds]
  /// after speech ends the turn and runs Whisper → Gemma.
  listening,

  /// Whisper and/or Gemma processing the last utterance.
  thinking,

  /// TTS is voicing the model's reply. Mic frames discarded.
  speaking,

  /// Recoverable error; auto-returns to [listening] after ~3 s.
  error,
}

/// Seconds of trailing silence (Silero `minSilenceDuration`) before a
/// turn is finalized and sent to Whisper.
const double kSilenceTriggerSeconds = 2.0;

extension HandsFreeStageX on HandsFreeStage {
  bool get isArmed => this != HandsFreeStage.disarmed;

  bool get isMicOwner => this == HandsFreeStage.listening;

  bool get isInputMuted =>
      this == HandsFreeStage.thinking || this == HandsFreeStage.speaking;
}

/// Snapshot the orchestrator emits on every state transition.
class HandsFreeSnapshot {
  const HandsFreeSnapshot({
    required this.stage,
    required this.statusLine,
    this.lastError,
  });

  final HandsFreeStage stage;
  final String statusLine;
  final String? lastError;

  HandsFreeSnapshot copyWith({
    HandsFreeStage? stage,
    String? statusLine,
    String? lastError,
    bool clearError = false,
  }) {
    return HandsFreeSnapshot(
      stage: stage ?? this.stage,
      statusLine: statusLine ?? this.statusLine,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }

  static const HandsFreeSnapshot disarmed = HandsFreeSnapshot(
    stage: HandsFreeStage.disarmed,
    statusLine: 'Tap GO HANDS-FREE to start.',
  );
}
