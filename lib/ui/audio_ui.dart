import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../modules/audio/audio_gateway.dart';
import '../modules/audio/conversation_turn.dart';
import '../modules/audio/multilingual_tts.dart';
import '../modules/audio/speech_synth.dart' show VoiceMissingException;
import '../modules/audio/streaming_tts_buffer.dart';
import '../modules/hands_free/hands_free_orchestrator.dart';
import '../modules/hands_free/hands_free_state.dart';
import '../modules/tools/breathing_pacer_tool.dart' show BreathPhase;
import '../modules/tools/tool_call.dart';
import '../modules/tools/tool_dispatcher.dart';
import '../modules/tools/tool_invocation.dart';
import '../constants/disclaimers.dart';
import '../database/medical_kb.dart';
import '../services/session_log.dart';
import '../theme/emergency_theme.dart';
import 'components/base_camp_components.dart';
import 'session_log_sheet.dart';
import 'session_logs_screen.dart';

/// Hands-free first-aid conversation screen.
///
/// Mirrors the `EmergencyUI` camera body: a full-height transcript
/// pane, a large mic button that mirrors the shutter button's
/// geometry, and the same red disclaimer banner. Tap the mic to
/// start listening; tap again to send. Agentic tools sit in a compact
/// vertical rail beside the mic; reset / stop-speaking are on that rail.
class AudioUI extends StatefulWidget {
  const AudioUI({
    super.key,
    required this.gateway,
    required this.tts,
    required this.tools,
    required this.handsFree,
    this.engineInitFuture,
  });

  final AudioGateway gateway;
  final MultilingualTTS tts;

  /// Shared agentic-tool dispatcher. Drives the active-tools tray, the
  /// breathing-pacer overlay, and the manual TOOLS row buttons. The
  /// same dispatcher instance is wired into [AudioGateway] so model-
  /// driven `<TOOL_CALL>` tags and manual taps share the execution
  /// path.
  final ToolDispatcher tools;

  /// Hands-free orchestrator: VAD silence → Whisper STT → Gemma.
  final HandsFreeOrchestrator handsFree;

  /// Completes when the shared [ModelEngine] has finished loading Gemma.
  /// System TTS init is gated on this so `isLanguageAvailable` does not
  /// race Gemma's native bring-up on low-RAM devices.
  final Future<void>? engineInitFuture;

  @override
  State<AudioUI> createState() => _AudioUIState();
}

class _AudioUIState extends State<AudioUI> {
  late StreamSubscription<GatewaySnapshot> _sub;
  late StreamSubscription<List<ToolInvocation>> _toolsSub;
  late StreamSubscription<HandsFreeSnapshot> _handsFreeSub;
  GatewaySnapshot? _snap;
  HandsFreeSnapshot _handsFreeSnap = HandsFreeSnapshot.disarmed;
  List<ToolInvocation> _toolInvocations = const <ToolInvocation>[];
  String? _fatalError;
  bool _synthReady = false;
  String? _lastSpokenTurnKey;
  String? _endedSessionLogPath;
  bool _endedSessionLogIsPdf = true;
  late final StreamingTtsBuffer _streamingTts;

  /// Drives the elapsed-time counter on tray cards and the breathing
  /// pacer's phase progress without forcing each tool to emit a
  /// dispatcher event every frame.
  Timer? _ticker;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _streamingTts = StreamingTtsBuffer(tts: widget.tts);
    widget.gateway.streamingTts = _streamingTts;
    _snap = widget.gateway.current;
    _sub = widget.gateway.snapshots.listen(_onSnapshot);
    _toolInvocations = widget.tools.current;
    _toolsSub = widget.tools.invocations.listen(_onToolInvocations);
    _handsFreeSnap = widget.handsFree.current;
    _handsFreeSub = widget.handsFree.snapshots.listen(_onHandsFreeSnapshot);
    unawaited(_warmSystemTts());
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      // Force a rebuild while at least one tool card is actively
      // counting up, OR while hands-free is in `listening` so the
      // pulsing dot animation has a tick to drive it. Skips waking
      // the framework four times a second when idle.
      final hasActive = _toolInvocations.any((i) => i.isActive);
      final pulsing = _handsFreeSnap.stage == HandsFreeStage.listening;
      if (hasActive || pulsing) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.gateway.streamingTts = null;
    _sub.cancel();
    _toolsSub.cancel();
    _handsFreeSub.cancel();
    _ticker?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onHandsFreeSnapshot(HandsFreeSnapshot s) {
    if (!mounted) return;
    setState(() => _handsFreeSnap = s);
  }

  void _onToolInvocations(List<ToolInvocation> list) {
    if (!mounted) return;
    setState(() => _toolInvocations = list);
  }

  void _onSnapshot(GatewaySnapshot snap) {
    if (!mounted) return;
    setState(() => _snap = snap);

    // Auto-scroll to the newest turn whenever the transcript grows.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });

    _maybeSpeak(snap);
  }

  /// When a model turn finishes (transitions from streaming to done),
  /// hand it to the TTS synth. We track the last spoken turn by index
  /// + final text length so a re-emitted snapshot doesn't double-play.
  ///
  /// If [StreamingTtsBuffer] already spoke sentences during generation
  /// we skip the full-text fallback to avoid double playback.
  void _maybeSpeak(GatewaySnapshot snap) {
    if (_fatalError != null) return;
    if (snap.turns.isEmpty) return;
    final last = snap.turns.last;
    if (last.role != TurnRole.model) return;
    if (last.isStreaming) return;
    if (last.text.trim().isEmpty) return;

    final key = '${snap.turns.length}:${last.text.length}';
    if (key == _lastSpokenTurnKey) return;
    _lastSpokenTurnKey = key;

    // Hands-free owns TTS + mic pause/resume; speaking here used to
    // disarm the loop and break the conversation.
    if (_handsFreeSnap.stage != HandsFreeStage.disarmed) return;

    // Streaming TTS already sent sentences to the engine — skip the
    // full-response fallback.
    if (_streamingTts.sentencesQueued > 0) return;

    unawaited(_speakModelTurn(last.text));
  }

  Future<void> _warmSystemTts() async {
    final pending = widget.engineInitFuture;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;
    try {
      await widget.tts.initialize();
      if (!mounted) return;
      if (widget.tts.isInitialized) {
        setState(() => _synthReady = true);
      }
    } on VoiceMissingException catch (e) {
      if (!mounted) return;
      setState(() {
        _fatalError =
            'System text-to-speech is not available for this locale.\n\n'
            'Tried:\n${e.searched.map((t) => '• $t').join('\n')}\n\n'
            'Install or enable a TTS engine in Android Settings → '
            'Accessibility / Text-to-speech, then relaunch Base Camp.';
      });
    } catch (e) {
      debugPrint('SpeechSynth.initialize failed: $e');
    }
  }

  Future<void> _speakModelTurn(String text) async {
    final pending = widget.engineInitFuture;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        return;
      }
    }
    if (!mounted) return;

    var spins = 0;
    while (mounted && widget.gateway.current.isThinking && spins < 240) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      spins++;
    }
    if (!mounted) return;

    try {
      final lang = widget.gateway.lastTurnLanguage ?? 'en';
      final result = await widget.tts.speakInLanguage(
        text: text,
        language: lang,
      );
      if (result.usedEnglishFallback) {
        widget.gateway.annotateLastModelTurnTtsFallback(
          MultilingualTTS.kTtsFallbackBanner,
        );
      }
      if (!mounted) return;
      if (!_synthReady && widget.tts.isInitialized) {
        setState(() => _synthReady = true);
      }
    } on VoiceMissingException catch (e) {
      if (!mounted) return;
      setState(() {
        _fatalError =
            'System text-to-speech is not available for this locale.\n\n'
            'Tried:\n${e.searched.map((t) => '• $t').join('\n')}\n\n'
            'Install or enable a TTS engine in Android Settings → '
            'Accessibility / Text-to-speech, then relaunch Base Camp.';
      });
    } catch (e) {
      debugPrint('SpeechSynth.speak failed: $e');
    }
  }

  Future<void> _endSession() async {
    _streamingTts.cancel();
    await widget.handsFree.disarm();
    await widget.tts.stop();
    await widget.tools.stopAll();
    final result = await SessionLog.endIfActive(reason: 'user');
    if (!mounted) return;
    if (result != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.userMessage)),
      );
    }
    setState(() {
      _endedSessionLogPath = result?.primaryPath;
      _endedSessionLogIsPdf = result?.pdfSaved ?? false;
      _lastSpokenTurnKey = null;
    });
    await widget.gateway.reset();
  }

  Future<void> _onMicTap() async {
    final snap = _snap;
    if (snap == null) return;

    if (snap.isListening) {
      await HapticFeedback.lightImpact();
      await widget.gateway.stop();
      return;
    }
    if (snap.isThinking || snap.isTranscribing) return;

    if (SessionLog.instance == null) {
      await SessionLog.start();
      if (mounted) setState(() => _endedSessionLogPath = null);
    }
    // Hands-free owns its own AudioRecorder while armed. Two recorders
    // cannot be open simultaneously on Android — disarm before capture.
    if (_handsFreeSnap.stage.isArmed) {
      await widget.handsFree.disarm();
    }
    await HapticFeedback.mediumImpact();
    await widget.tts.stop();
    await widget.gateway.start();
  }

  Future<void> _onHandsFreeBannerTap() async {
    final stage = _handsFreeSnap.stage;
    if (stage == HandsFreeStage.disarmed) {
      // If the previous arm() failed (most commonly because the
      // sherpa KWS / VAD models aren't installed on this device),
      // tapping the banner pulls up a help sheet first instead of
      // silently retrying. The sheet itself offers a RETRY button that
      // calls back into [_armHandsFree] when the responder has done
      // the install.
      final lastErr = _handsFreeSnap.lastError;
      if (lastErr != null && lastErr.trim().isNotEmpty) {
        await _showHandsFreeHelpSheet(lastErr);
        return;
      }
      await _armHandsFree();
    } else {
      await HapticFeedback.lightImpact();
      await widget.handsFree.disarm();
    }
  }

  Future<void> _armHandsFree() async {
    // Block press-to-talk recordings from racing arm() — the gateway
    // and orchestrator share the LiteRT conversation slot.
    if (_snap?.isListening == true || _snap?.isThinking == true) {
      await widget.gateway.cancel();
    }
    await HapticFeedback.mediumImpact();
    try {
      await widget.handsFree.arm();
    } catch (_) {
      // arm() already published the failure on the snapshot stream;
      // the banner re-renders with the missing-models hint and the
      // next tap will surface the help sheet.
    }
  }

  Future<void> _showHandsFreeHelpSheet(String lastError) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _HandsFreeHelpSheet(
        lastError: lastError,
        onRetry: () async {
          Navigator.of(ctx).pop();
          await _armHandsFree();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_fatalError != null) {
      return _AudioFatalGate(message: _fatalError!);
    }
    final snap = _snap;
    final turns = snap?.turns ?? const <ConversationTurn>[];

    return Scaffold(
      backgroundColor: EmergencyPalette.background,
      appBar: AppBar(
        title: const Text('Ask'),
        actions: [
          IconButton(
            tooltip: 'Session logs',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SessionLogsScreen(),
                ),
              );
            },
            icon: const Icon(Icons.folder_open_rounded),
          ),
          Builder(
            builder: (context) {
              final screenW = MediaQuery.sizeOf(context).width;
              final narrow = screenW < 420;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(260, screenW * 0.5),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        BaseCampStatusBadge(
                          icon: Icons.graphic_eq_rounded,
                          label: (_synthReady || widget.tts.isInitialized)
                              ? (narrow ? 'Voice OK' : 'Voice ready')
                              : (narrow ? 'TTS…' : 'TTS loading'),
                          ready: _synthReady || widget.tts.isInitialized,
                        ),
                        const SizedBox(width: 8),
                        _HandsFreeStatusChip(
                          snapshot: _handsFreeSnap,
                          compact: narrow,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              const BaseCampHeaderAccent(),
              Expanded(
                child: turns.isEmpty
                    ? const _EmptyTranscriptHint()
                    : ListView.builder(
                        controller: _scrollController,
                        padding:
                            const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        itemCount: turns.length,
                        itemBuilder: (ctx, i) => _TurnCard(turn: turns[i]),
                      ),
              ),
              if (snap?.error != null) _ErrorBanner(text: snap!.error!),
              if (_endedSessionLogPath != null)
                SessionEndedBanner(
                  logPath: _endedSessionLogPath!,
                  isPdf: _endedSessionLogIsPdf,
                  onDismiss: () =>
                      setState(() => _endedSessionLogPath = null),
                ),
              _ActiveToolsTray(
                invocations: _toolInvocations,
                onStop: (id) => widget.tools.stop(id),
              ),
              _AskBottomDock(
                enabled: _handsFreeManualEnabled,
                listening: snap?.isListening ?? false,
                thinking: (snap?.isThinking ?? false) ||
                    (snap?.isTranscribing ?? false),
                handsFreeBlocked: !_handsFreeManualEnabled,
                onOpenTools: () => _openToolsPanel(context),
                onStopSpeaking: () async {
                  _streamingTts.cancel();
                  await widget.tts.stop();
                },
                onEndSession: _endSession,
                onMicTap: _onMicTap,
              ),
              const SizedBox(height: 8),
              BaseCampDisclaimerBanner(text: kNonDiagnosticDisclaimer),
            ],
          ),
          // The breathing pacer overlays the entire ASK screen while
          // it's running so the patient can follow the ring without
          // chrome distractions. Tapping it stops the exercise; the
          // tray entry remains visible behind for the responder.
          if (_activeBreathingInvocation() != null)
            _BreathingOverlay(
              invocation: _activeBreathingInvocation()!,
              onStop: () => widget.tools
                  .stop(_activeBreathingInvocation()!.id),
            ),
        ],
      ),
    );
  }

  ToolInvocation? _activeBreathingInvocation() {
    for (final inv in _toolInvocations) {
      if (inv.name == 'breathing_pacer' && inv.isActive) return inv;
    }
    return null;
  }

  /// True when the tap-to-talk mic button + the manual TOOLS row
  /// should accept input. The plan keeps both enabled in `disarmed`
  /// while hands-free is disarmed only (armed mode owns the mic stream).
  /// [HandsFreeOrchestrator.disarm] in [_onMicTap] before opening
  /// the gateway recorder). Everything else (booting, listening,
  /// thinking, speaking, error) hides the manual surface so a stray
  /// finger can't fight the orchestrator.
  bool get _handsFreeManualEnabled {
    final s = _handsFreeSnap.stage;
    return s == HandsFreeStage.disarmed;
  }

  // ------------------------------------------------------------------
  // Manual tool sheets
  // ------------------------------------------------------------------

  Future<void> _openToolsPanel(BuildContext ctx) async {
    await showModalBottomSheet<void>(
      context: ctx,
      backgroundColor: EmergencyPalette.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(EmergencyPalette.radiusXl),
        ),
      ),
      builder: (sheetCtx) => _ToolsPanelSheet(
        handsFree: _handsFreeSnap,
        onCpr: () {
          Navigator.of(sheetCtx).pop();
          _openCprSheet(ctx);
        },
        onBreathing: () {
          Navigator.of(sheetCtx).pop();
          _openBreathingSheet(ctx);
        },
        onTimer: () {
          Navigator.of(sheetCtx).pop();
          _openTimerSheet(ctx);
        },
        onToggleHandsFree: () async {
          Navigator.of(sheetCtx).pop();
          await _onHandsFreeBannerTap();
        },
        onEndSession: () async {
          Navigator.of(sheetCtx).pop();
          await _endSession();
        },
      ),
    );
  }

  Future<void> _openCprSheet(BuildContext ctx) async {
    final result = await showModalBottomSheet<_CprSheetResult>(
      context: ctx,
      builder: (_) => const _CprArgSheet(),
    );
    if (result == null || !mounted) return;
    await SessionLog.instance?.userResponse(true);
    await widget.tools.execute(ToolCall(
      name: 'cpr_cadence',
      args: <String, Object?>{
        'bpm': result.bpm,
        'label': result.patient,
      },
    ));
  }

  Future<void> _openBreathingSheet(BuildContext ctx) async {
    final result = await showModalBottomSheet<_BreathingSheetResult>(
      context: ctx,
      builder: (_) => const _BreathingArgSheet(),
    );
    if (result == null || !mounted) return;
    await SessionLog.instance?.userResponse(true);
    await widget.tools.execute(ToolCall(
      name: 'breathing_pacer',
      args: <String, Object?>{
        'pattern': result.pattern,
        'cycles': result.cycles,
      },
    ));
  }

  Future<void> _openTimerSheet(BuildContext ctx) async {
    final result = await showModalBottomSheet<_TimerSheetResult>(
      context: ctx,
      builder: (_) => const _TimerArgSheet(),
    );
    if (result == null || !mounted) return;
    await SessionLog.instance?.userResponse(true);
    await widget.tools.execute(ToolCall(
      name: 'medical_timer',
      args: <String, Object?>{
        'kind': result.kind,
        'label': result.label,
        if (result.alertMinutes.isNotEmpty)
          'alert_minutes': result.alertMinutes,
      },
    ));
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _EmptyTranscriptHint extends StatelessWidget {
  const _EmptyTranscriptHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: EmergencyPalette.emergencyRed.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(
                  color: EmergencyPalette.emergencyRed.withValues(alpha: 0.3),
                ),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.mic_rounded,
                size: 40,
                color: EmergencyPalette.emergencyRed,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Tap the mic to speak',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: EmergencyPalette.onSurface,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Ask a first-aid question out loud. Tap again to send. '
              'Base Camp answers offline in your language.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _TurnCard extends StatelessWidget {
  const _TurnCard({required this.turn});
  final ConversationTurn turn;

  @override
  Widget build(BuildContext context) {
    final isUser = turn.role == TurnRole.user;
    final isSystem = turn.role == TurnRole.system;
    final bg = isUser
        ? EmergencyPalette.emergencyRed.withValues(alpha: 0.85)
        : isSystem
            ? EmergencyPalette.surface
            : EmergencyPalette.surfaceElevated;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final label = isUser ? 'You' : (isSystem ? 'System' : 'Base Camp');
    final renderText =
        turn.text.isEmpty && turn.isStreaming ? '…' : turn.text;
    final stepBlocks =
        (!isUser && !isSystem) ? _extractNumberedSteps(renderText) : const [];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                  color: EmergencyPalette.onSurfaceMuted,
                ),
              ),
              if (!isUser && !isSystem) ...[
                const SizedBox(width: 8),
                _MiniGroundingChip(grounded: turn.grounded),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.88,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(EmergencyPalette.radiusMd),
                topRight: const Radius.circular(EmergencyPalette.radiusMd),
                bottomLeft: Radius.circular(
                  isUser ? EmergencyPalette.radiusSm : EmergencyPalette.radiusMd,
                ),
                bottomRight: Radius.circular(
                  isUser ? EmergencyPalette.radiusMd : EmergencyPalette.radiusSm,
                ),
              ),
              border: isSystem
                  ? Border.all(color: EmergencyPalette.outlineSubtle)
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final w in turn.warnings) ...[
                  _MiniWarning(text: w),
                  const SizedBox(height: 6),
                ],
                if (stepBlocks.isEmpty)
                  Text(
                    renderText,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.4,
                      color: EmergencyPalette.onSurface,
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (int i = 0; i < stepBlocks.length; i++) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: EmergencyPalette.background.withValues(
                              alpha: 0.35,
                            ),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: EmergencyPalette.outline,
                              width: 1,
                            ),
                          ),
                          child: RichText(
                            text: TextSpan(
                              children: [
                                TextSpan(
                                  text:
                                      'Step ${stepBlocks[i].number}: ',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.3,
                                    color: EmergencyPalette.triageYellow,
                                  ),
                                ),
                                TextSpan(
                                  text: stepBlocks[i].text,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    height: 1.35,
                                    color: EmergencyPalette.onSurface,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (i != stepBlocks.length - 1)
                          const SizedBox(height: 8),
                      ],
                    ],
                  ),
                if (turn.isStreaming) ...[
                  const SizedBox(height: 8),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: EmergencyPalette.emergencyRed,
                    ),
                  ),
                ],
                if (turn.toolInvocationIds.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(
                        Icons.bolt,
                        size: 14,
                        color: EmergencyPalette.triageYellow,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Tools fired: ${turn.toolInvocationIds.length}'
                          ' \u2014 see tray below',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: EmergencyPalette.triageYellow,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (!isUser && !isSystem && !turn.isStreaming) ...[
                  const SizedBox(height: 10),
                  _RagRetrievalDropdown(protocols: turn.protocols),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepBlock {
  const _StepBlock({required this.number, required this.text});
  final String number;
  final String text;
}

List<_StepBlock> _extractNumberedSteps(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const [];
  final rx = RegExp(r'^\s*(\d+)\.\s+', multiLine: true);
  final matches = rx.allMatches(text).toList();
  if (matches.isEmpty) return const [];

  final out = <_StepBlock>[];
  for (int i = 0; i < matches.length; i++) {
    final m = matches[i];
    final start = m.end;
    final end = (i + 1 < matches.length) ? matches[i + 1].start : text.length;
    final body = text.substring(start, end).trim();
    if (body.isEmpty) continue;
    out.add(_StepBlock(number: m.group(1)!, text: body));
  }
  return out;
}

/// Collapsible panel showing local KB chunks retrieved for a turn.
class _RagRetrievalDropdown extends StatefulWidget {
  const _RagRetrievalDropdown({required this.protocols});

  final List<ProtocolHit> protocols;

  @override
  State<_RagRetrievalDropdown> createState() => _RagRetrievalDropdownState();
}

class _RagRetrievalDropdownState extends State<_RagRetrievalDropdown> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final count = widget.protocols.length;
    final accent = count > 0
        ? EmergencyPalette.triageGreen
        : EmergencyPalette.onSurfaceMuted;

    return Material(
      color: EmergencyPalette.background.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _expanded = !_expanded);
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: EmergencyPalette.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'RAG RETRIEVAL ($count)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.0,
                      color: accent,
                    ),
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 8),
                if (count == 0)
                  const Text(
                    'No protocol matches were retrieved for this turn.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: EmergencyPalette.onSurfaceMuted,
                    ),
                  )
                else
                  for (int i = 0; i < widget.protocols.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _RagHitTile(hit: widget.protocols[i], index: i + 1),
                  ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RagHitTile extends StatelessWidget {
  const _RagHitTile({required this.hit, required this.index});

  final ProtocolHit hit;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scorePct = (hit.score * 100).round();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: EmergencyPalette.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: EmergencyPalette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$index. ${hit.title}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: EmergencyPalette.onSurface,
                  ),
                ),
              ),
              Text(
                '$scorePct%',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: EmergencyPalette.triageGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            hit.snippet,
            style: const TextStyle(
              fontSize: 12,
              height: 1.35,
              color: EmergencyPalette.onSurfaceMuted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hit.citation.provenanceLine,
            style: const TextStyle(
              fontSize: 10,
              fontStyle: FontStyle.italic,
              color: EmergencyPalette.onSurfaceMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniGroundingChip extends StatelessWidget {
  const _MiniGroundingChip({required this.grounded});
  final bool grounded;

  @override
  Widget build(BuildContext context) {
    return BaseCampGroundingChip(grounded: grounded);
  }
}

class _MiniWarning extends StatelessWidget {
  const _MiniWarning({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: EmergencyPalette.emergencyRed,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: EmergencyPalette.onSurface,
            size: 14,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(
                color: EmergencyPalette.onSurface,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mic button diameter (~18% smaller than the prior 88 px).
const double _kAskMicSize = 72;

/// Read-only hands-free indicator for the app bar (not tappable).
class _HandsFreeStatusChip extends StatelessWidget {
  const _HandsFreeStatusChip({
    required this.snapshot,
    this.compact = false,
  });

  final HandsFreeSnapshot snapshot;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final on = snapshot.stage.isArmed;
    final color =
        on ? EmergencyPalette.triageGreen : EmergencyPalette.onSurfaceMuted;
    final label = compact
        ? (on ? 'HF on' : 'HF off')
        : (on ? 'Hands-free on' : 'Hands-free off');
    return Tooltip(
      message: on
          ? 'Hands-free mode is on — tap the banner to stop'
          : 'Hands-free mode is off — tap the banner to start',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: compact ? 0.2 : 0.3,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom control stack: quick actions, mic, reset, disclaimer above.
class _AskBottomDock extends StatelessWidget {
  const _AskBottomDock({
    required this.enabled,
    required this.listening,
    required this.thinking,
    required this.handsFreeBlocked,
    required this.onOpenTools,
    required this.onStopSpeaking,
    required this.onEndSession,
    required this.onMicTap,
  });

  final bool enabled;
  final bool listening;
  final bool thinking;
  final bool handsFreeBlocked;
  final VoidCallback onOpenTools;
  final Future<void> Function() onStopSpeaking;
  final Future<void> Function() onEndSession;
  final Future<void> Function() onMicTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: _QuickActionButton(
                  icon: Icons.build_rounded,
                  label: 'Tools',
                  onPressed: onOpenTools,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _QuickActionButton(
                  icon: Icons.stop_circle_outlined,
                  label: 'Stop Speaking',
                  onPressed: () => onStopSpeaking(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: _kAskMicSize + 20,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: _SessionResetButton(
                    onPressed: () => onEndSession(),
                  ),
                ),
                Opacity(
                  opacity: enabled ? 1 : 0.45,
                  child: IgnorePointer(
                    ignoring: !enabled,
                    child: _MicButton(
                      size: _kAskMicSize,
                      listening: listening,
                      thinking: thinking,
                      handsFreeBlocked: handsFreeBlocked,
                      onMicTap: onMicTap,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: EmergencyPalette.surfaceElevated,
      borderRadius: BorderRadius.circular(EmergencyPalette.radiusMd),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onPressed();
        },
        borderRadius: BorderRadius.circular(EmergencyPalette.radiusMd),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(EmergencyPalette.radiusMd),
            border: Border.all(color: EmergencyPalette.outlineSubtle),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: EmergencyPalette.onSurface),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: EmergencyPalette.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionResetButton extends StatelessWidget {
  const _SessionResetButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () {
        HapticFeedback.selectionClick();
        onPressed();
      },
      style: TextButton.styleFrom(
        foregroundColor: EmergencyPalette.onSurfaceMuted,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      icon: const Icon(Icons.refresh_rounded, size: 18),
      label: const Text('Reset'),
    );
  }
}

/// Agentic tools + hands-free toggle (opened from the Tools quick action).
class _ToolsPanelSheet extends StatelessWidget {
  const _ToolsPanelSheet({
    required this.handsFree,
    required this.onCpr,
    required this.onBreathing,
    required this.onTimer,
    required this.onToggleHandsFree,
    required this.onEndSession,
  });

  final HandsFreeSnapshot handsFree;
  final VoidCallback onCpr;
  final VoidCallback onBreathing;
  final VoidCallback onTimer;
  final Future<void> Function() onToggleHandsFree;
  final Future<void> Function() onEndSession;

  @override
  Widget build(BuildContext context) {
    final hfOn = handsFree.stage.isArmed;
    final hfError =
        handsFree.lastError != null && handsFree.lastError!.trim().isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BaseCampSheetHeader(
              title: 'Tools',
              icon: Icons.build_rounded,
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 16),
            _ToolsPanelTile(
              icon: Icons.favorite_rounded,
              label: 'CPR metronome',
              onTap: onCpr,
            ),
            const SizedBox(height: 8),
            _ToolsPanelTile(
              icon: Icons.air_rounded,
              label: 'Breathing pacer',
              onTap: onBreathing,
            ),
            const SizedBox(height: 8),
            _ToolsPanelTile(
              icon: Icons.timer_outlined,
              label: 'Medical timer',
              onTap: onTimer,
            ),
            const SizedBox(height: 8),
            _ToolsPanelTile(
              icon: hfOn ? Icons.headset_off_rounded : Icons.headset_mic_rounded,
              label: hfOn
                  ? 'Turn off hands-free'
                  : hfError
                      ? 'Hands-free (setup required)'
                      : 'Turn on hands-free',
              subtitle: hfOn ? handsFree.statusLine : null,
              onTap: () => onToggleHandsFree(),
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            _ToolsPanelTile(
              icon: Icons.logout_rounded,
              label: 'End session',
              destructive: true,
              onTap: () => onEndSession(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolsPanelTile extends StatelessWidget {
  const _ToolsPanelTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool destructive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = destructive
        ? EmergencyPalette.emergencyRed
        : EmergencyPalette.onSurface;
    return Material(
      color: EmergencyPalette.surface,
      borderRadius: BorderRadius.circular(EmergencyPalette.radiusMd),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(EmergencyPalette.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: EmergencyPalette.onSurfaceMuted,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: EmergencyPalette.onSurfaceMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.size,
    required this.listening,
    required this.thinking,
    required this.onMicTap,
    this.handsFreeBlocked = false,
  });

  final double size;
  final bool listening;
  final bool thinking;

  /// True while the hands-free orchestrator owns the mic stream and a
  /// manual tap would race with it. The button still renders (keeps
  /// the layout stable) but is muted and ignores input.
  final bool handsFreeBlocked;

  final Future<void> Function() onMicTap;

  @override
  Widget build(BuildContext context) {
    final disabled = thinking || handsFreeBlocked;
    return BaseCampCircularAction(
      size: size,
      busy: thinking,
      color: listening
          ? EmergencyPalette.triageYellow
          : disabled
              ? EmergencyPalette.emergencyRedDeep
              : EmergencyPalette.emergencyRed,
      ringColor: listening
          ? EmergencyPalette.triageYellow.withValues(alpha: 0.4)
          : EmergencyPalette.emergencyRedGlow,
      icon: handsFreeBlocked
          ? Icons.mic_off_rounded
          : listening
              ? Icons.stop_rounded
              : Icons.mic_rounded,
      iconColor: listening
          ? EmergencyPalette.background
          : EmergencyPalette.onSurface,
      onTap: disabled ? null : () => onMicTap(),
      semanticsLabel: handsFreeBlocked
          ? 'Hands-free is active — tap the banner to stop'
          : listening
              ? 'Tap to send'
              : thinking
                  ? 'Model is responding'
                  : 'Tap to speak',
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: EmergencyPalette.emergencyRed,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline,
            color: EmergencyPalette.onSurface,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: EmergencyPalette.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Agentic tools — active-tools tray
// ---------------------------------------------------------------------------

class _ActiveToolsTray extends StatelessWidget {
  const _ActiveToolsTray({
    required this.invocations,
    required this.onStop,
  });

  final List<ToolInvocation> invocations;
  final Future<void> Function(String invocationId) onStop;

  @override
  Widget build(BuildContext context) {
    final active = invocations.where((i) => i.isActive).toList();
    if (active.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final inv in active)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _ToolTrayCard(
                invocation: inv,
                onStop: () => onStop(inv.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolTrayCard extends StatelessWidget {
  const _ToolTrayCard({required this.invocation, required this.onStop});

  final ToolInvocation invocation;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final elapsed = invocation.elapsed;
    final isTourniquet =
        invocation.name == 'medical_timer' && invocation.kind == 'tourniquet';
    final overOneHour = isTourniquet && elapsed.inMinutes >= 60;
    final overTwoHours = isTourniquet && elapsed.inMinutes >= 120;

    final accent = invocation.name == 'cpr_cadence'
        ? EmergencyPalette.emergencyRed
        : invocation.name == 'breathing_pacer'
            ? EmergencyPalette.triageGreen
            : overTwoHours
                ? EmergencyPalette.emergencyRed
                : overOneHour
                    ? EmergencyPalette.triageYellow
                    : EmergencyPalette.onSurface;

    final alertActive = invocation.lastAlertAt != null &&
        DateTime.now().difference(invocation.lastAlertAt!) <
            const Duration(seconds: 4);

    return Container(
      decoration: BoxDecoration(
        color: alertActive
            ? EmergencyPalette.emergencyRedDeep.withValues(alpha: 0.9)
            : EmergencyPalette.surfaceElevated,
        borderRadius: BorderRadius.circular(EmergencyPalette.radiusMd),
        border: Border.all(color: accent, width: alertActive ? 2 : 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(_iconFor(invocation), color: accent, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  invocation.label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: EmergencyPalette.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _detailFor(invocation),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: accent,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              onStop();
            },
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(64, 36),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              side: const BorderSide(
                color: EmergencyPalette.outline,
                width: 1,
              ),
            ),
            child: const Text(
              'STOP',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(ToolInvocation inv) {
    switch (inv.name) {
      case 'cpr_cadence':
        return Icons.favorite;
      case 'breathing_pacer':
        return Icons.air;
      case 'medical_timer':
        return inv.kind == 'tourniquet'
            ? Icons.bloodtype_outlined
            : Icons.timer_outlined;
      default:
        return Icons.bolt;
    }
  }

  String _detailFor(ToolInvocation inv) {
    final hh = inv.elapsed.inHours.toString().padLeft(2, '0');
    final mm = (inv.elapsed.inMinutes % 60).toString().padLeft(2, '0');
    final ss = (inv.elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final base = '$hh:$mm:$ss';

    if (inv.name == 'cpr_cadence') {
      final bpm = inv.payload?['bpm'];
      return 'BEAT · $base · $bpm BPM';
    }
    if (inv.name == 'breathing_pacer') {
      final phase = inv.payload?['phase_label'] ?? '';
      final done = inv.payload?['cycles_done'] ?? 0;
      final total = inv.payload?['cycles_total'] ?? 0;
      return '$phase · cycle $done / $total · $base';
    }
    if (inv.name == 'medical_timer') {
      final fired = (inv.payload?['alerts_fired'] as List?)?.length ?? 0;
      final scheduled =
          (inv.payload?['alerts_minutes'] as List?)?.length ?? 0;
      if (scheduled > 0) {
        return 'ELAPSED $base · alerts $fired / $scheduled';
      }
      return 'ELAPSED $base';
    }
    return base;
  }
}

// ---------------------------------------------------------------------------
// Agentic tools — breathing pacer overlay
// ---------------------------------------------------------------------------

class _BreathingOverlay extends StatelessWidget {
  const _BreathingOverlay({
    required this.invocation,
    required this.onStop,
  });

  final ToolInvocation invocation;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final payload = invocation.payload ?? const <String, Object?>{};
    final phaseName = payload['phase'] as String? ?? BreathPhase.inhale.name;
    final phaseLabel =
        payload['phase_label'] as String? ?? 'Breathe in';
    final phase = BreathPhase.values.firstWhere(
      (p) => p.name == phaseName,
      orElse: () => BreathPhase.inhale,
    );
    final phaseTotalMs = (payload['phase_total_ms'] as num?)?.toInt() ?? 4000;
    final phaseStartedAtMs =
        (payload['phase_started_at_ms'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch;
    final cyclesDone = (payload['cycles_done'] as num?)?.toInt() ?? 0;
    final cyclesTotal = (payload['cycles_total'] as num?)?.toInt() ?? 0;

    final elapsedMs =
        DateTime.now().millisecondsSinceEpoch - phaseStartedAtMs;
    final t = phaseTotalMs <= 0
        ? 1.0
        : (elapsedMs / phaseTotalMs).clamp(0.0, 1.0);

    final scale = _scaleFor(phase, t);
    final remainSec = phaseTotalMs <= 0
        ? 0
        : ((phaseTotalMs - elapsedMs).clamp(0, phaseTotalMs) / 1000)
            .ceil();

    return Positioned.fill(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onStop();
        },
        child: Container(
          color: EmergencyPalette.background.withValues(alpha: 0.94),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'PANIC BREATHING',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                  color: EmergencyPalette.onSurfaceMuted,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 280,
                height: 280,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 240 * scale,
                      height: 240 * scale,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: EmergencyPalette.triageGreen
                            .withValues(alpha: 0.18),
                        border: Border.all(
                          color: EmergencyPalette.triageGreen,
                          width: 3,
                        ),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          phaseLabel,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.2,
                            color: EmergencyPalette.onSurface,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${remainSec}s',
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            color: EmergencyPalette.triageGreen,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Cycle ${cyclesDone + 1} / $cyclesTotal',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: EmergencyPalette.onSurfaceMuted,
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'TAP TO STOP',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.3,
                  color: EmergencyPalette.onSurfaceMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _scaleFor(BreathPhase phase, double t) {
    switch (phase) {
      case BreathPhase.inhale:
        return 0.55 + 0.45 * t;
      case BreathPhase.holdAfterInhale:
        return 1.0;
      case BreathPhase.exhale:
        return 1.0 - 0.45 * t;
      case BreathPhase.holdAfterExhale:
        return 0.55;
    }
  }
}

// ---------------------------------------------------------------------------
// Agentic tools — manual arg sheets
// ---------------------------------------------------------------------------

class _CprSheetResult {
  const _CprSheetResult({required this.bpm, required this.patient});
  final int bpm;
  final String patient;
}

class _CprArgSheet extends StatefulWidget {
  const _CprArgSheet();

  @override
  State<_CprArgSheet> createState() => _CprArgSheetState();
}

class _CprArgSheetState extends State<_CprArgSheet> {
  double _bpm = 110;
  String _patient = 'adult';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'CPR CADENCE',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Rate · ${_bpm.round()} BPM',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            Slider(
              min: 90,
              max: 120,
              divisions: 30,
              value: _bpm,
              onChanged: (v) => setState(() => _bpm = v),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final p in const ['adult', 'child', 'infant'])
                  ChoiceChip(
                    selected: _patient == p,
                    label: Text(p.toUpperCase()),
                    onSelected: (_) => setState(() => _patient = p),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                _CprSheetResult(
                  bpm: _bpm.round(),
                  patient: _patient,
                ),
              ),
              child: const Text('START METRONOME'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BreathingSheetResult {
  const _BreathingSheetResult({
    required this.pattern,
    required this.cycles,
  });
  final String pattern;
  final int cycles;
}

class _BreathingArgSheet extends StatefulWidget {
  const _BreathingArgSheet();

  @override
  State<_BreathingArgSheet> createState() => _BreathingArgSheetState();
}

class _BreathingArgSheetState extends State<_BreathingArgSheet> {
  String _pattern = 'box';
  int _cycles = 5;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'BREATHING PACER',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  selected: _pattern == 'box',
                  label: const Text('BOX (4-4-4-4)'),
                  onSelected: (_) => setState(() => _pattern = 'box'),
                ),
                ChoiceChip(
                  selected: _pattern == '4-7-8',
                  label: const Text('4-7-8'),
                  onSelected: (_) => setState(() => _pattern = '4-7-8'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Cycles · $_cycles',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            Slider(
              min: 1,
              max: 12,
              divisions: 11,
              value: _cycles.toDouble(),
              onChanged: (v) => setState(() => _cycles = v.round()),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                _BreathingSheetResult(
                  pattern: _pattern,
                  cycles: _cycles,
                ),
              ),
              child: const Text('START PACER'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimerSheetResult {
  const _TimerSheetResult({
    required this.kind,
    required this.label,
    required this.alertMinutes,
  });
  final String kind;
  final String label;
  final List<int> alertMinutes;
}

class _TimerArgSheet extends StatefulWidget {
  const _TimerArgSheet();

  @override
  State<_TimerArgSheet> createState() => _TimerArgSheetState();
}

class _TimerArgSheetState extends State<_TimerArgSheet> {
  String _kind = 'tourniquet';
  final TextEditingController _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = _kind == 'tourniquet'
        ? 'e.g. Left thigh tourniquet'
        : _kind == 'checkup'
            ? 'e.g. Bleeding re-check'
            : 'Label';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'MEDICAL TIMER',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  selected: _kind == 'tourniquet',
                  label: const Text('TOURNIQUET'),
                  onSelected: (_) => setState(() => _kind = 'tourniquet'),
                ),
                ChoiceChip(
                  selected: _kind == 'checkup',
                  label: const Text('CHECKUP'),
                  onSelected: (_) => setState(() => _kind = 'checkup'),
                ),
                ChoiceChip(
                  selected: _kind == 'generic',
                  label: const Text('GENERIC'),
                  onSelected: (_) => setState(() => _kind = 'generic'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              autofocus: true,
              maxLength: 64,
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () {
                final raw = _label.text.trim();
                Navigator.of(context).pop(
                  _TimerSheetResult(
                    kind: _kind,
                    label: raw,
                    alertMinutes: const <int>[],
                  ),
                );
              },
              child: const Text('START TIMER'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hands-free help sheet (shown when the sherpa KWS/VAD models are missing)
// ---------------------------------------------------------------------------

class _HandsFreeHelpSheet extends StatelessWidget {
  const _HandsFreeHelpSheet({
    required this.lastError,
    required this.onRetry,
  });

  final String lastError;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.headset_mic,
                    color: EmergencyPalette.emergencyRed,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'HANDS-FREE UNAVAILABLE',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.4,
                      color: EmergencyPalette.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'The hands-free conversation loop needs on-device speech '
                'assets that are not currently on this device:',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: EmergencyPalette.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '  • assets/whisper/ggml-tiny.bin\n'
                '  • assets/sherpa/vad/silero_vad.onnx',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.5,
                  color: EmergencyPalette.onSurfaceMuted,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'See assets/whisper/README.md and assets/sherpa/README.md '
                'for install / adb-push checklists, then RETRY below.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: EmergencyPalette.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                "Tap-to-talk mic still works without these models — "
                "you just won't get hands-free VAD or automatic turn-"
                "of-utterance segmentation.",
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                  color: EmergencyPalette.onSurfaceMuted,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: EmergencyPalette.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: EmergencyPalette.outline,
                    width: 1,
                  ),
                ),
                child: Text(
                  lastError,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.45,
                    color: EmergencyPalette.onSurfaceMuted,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('CLOSE'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => onRetry(),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('RETRY'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fatal gate
// ---------------------------------------------------------------------------

class _AudioFatalGate extends StatelessWidget {
  const _AudioFatalGate({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EmergencyPalette.background,
      appBar: AppBar(title: const Text('ASK')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.volume_off_rounded,
                size: 56,
                color: EmergencyPalette.emergencyRed,
              ),
              const SizedBox(height: 16),
              const Text(
                'VOICE GATEWAY OFFLINE',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                  color: EmergencyPalette.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  color: EmergencyPalette.onSurfaceMuted,
                ),
              ),
              const SizedBox(height: 24),
              BaseCampDisclaimerBanner(text: kNonDiagnosticDisclaimer),
            ],
          ),
        ),
      ),
    );
  }
}
