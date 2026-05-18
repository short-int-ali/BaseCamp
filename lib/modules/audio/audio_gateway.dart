import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../database/file_medical_kb.dart';
import '../../database/medical_kb.dart';
import '../../services/camera_capture_host.dart';
import '../../services/model_engine.dart';
import '../../services/session_log.dart';
import '../../services/language_detector.dart';
import '../../services/whisper_transcriber.dart';
import '../tools/tool_call.dart';
import '../tools/tool_call_parser.dart';
import '../tools/tool_dispatcher.dart';
import '../vision/vision_result.dart' show KbCitation;
import 'conversation_turn.dart';
import 'prompts.dart';
import 'streaming_tts_buffer.dart';

/// Hard cap on recording length. Gemma 4's audio tower is trained on
/// windows up to 30 s; clips longer than that get silently truncated
/// by the runtime, which confuses ASR alignment and inflates the
/// prefill budget.
const Duration kMaxRecordingLength = Duration(seconds: 30);

/// Snapshot the audio gateway emits after every state change — one
/// event per streamed token, plus boundary events (user turn
/// committed, reset, error).
class GatewaySnapshot {
  const GatewaySnapshot({
    required this.turns,
    required this.isListening,
    required this.isThinking,
    this.isTranscribing = false,
    this.error,
  });

  /// The full transcript, oldest first. The last entry may be a
  /// streaming model turn (`isStreaming = true`).
  final List<ConversationTurn> turns;

  /// True while the mic is actively capturing audio. The UI tints the
  /// shutter while this is on.
  final bool isListening;

  /// True from the moment we hand audio to the model until the stream
  /// completes. Disables the mic button.
  final bool isThinking;

  /// True while Whisper GGML is decoding the user's clip (before Gemma).
  final bool isTranscribing;

  /// Non-null if the most recent operation failed. Transient — cleared
  /// on the next successful turn. The UI renders it as a red banner.
  final String? error;
}

/// Gemma-powered conversational first-aid gateway.
///
/// One long-lived [LiteLmConversation] holds the full dialogue state
/// so the model can refer back to earlier turns (e.g. "what about
/// compression depth for the same case?"). [reset] tears it down and
/// starts a new one.
class AudioGateway {
  AudioGateway({
    required ModelEngine engine,
    required MedicalKb kb,
    required ToolDispatcher tools,
    required WhisperTranscriber whisper,
    CameraCaptureHost? cameraHost,
    Future<void> Function()? onBeforeCameraModal,
    AudioRecorder? recorder,
  })  : _engine = engine,
        _kb = kb,
        _tools = tools,
        _whisper = whisper,
        _cameraHost = cameraHost,
        _onBeforeCameraModal = onBeforeCameraModal,
        _recorder = recorder ?? AudioRecorder();

  final ModelEngine _engine;
  final MedicalKb _kb;
  final ToolDispatcher _tools;
  final WhisperTranscriber _whisper;
  final CameraCaptureHost? _cameraHost;
  final Future<void> Function()? _onBeforeCameraModal;
  final AudioRecorder _recorder;

  /// Set when Gemma emits `request_camera_mode` during a turn; handled
  /// after the initial text stream completes.
  ToolCall? _pendingCameraCall;

  /// Streaming TTS — sentences are spoken as they arrive from Gemma.
  /// Set by the owner (AudioUI / HandsFreeOrchestrator) after construction.
  StreamingTtsBuffer? streamingTts;

  LiteLmConversation? _conversation;
  bool _conversationBroken = false;
  String? _conversationLanguage;
  String? _lastTurnLanguage;

  final List<ConversationTurn> _turns = <ConversationTurn>[];
  bool _isListening = false;
  bool _isThinking = false;
  bool _isTranscribing = false;
  String? _lastError;

  /// Absolute path of the current in-progress recording (null when
  /// the mic is idle).
  String? _currentRecordingPath;
  Timer? _recordingTimeoutTimer;

  /// Monotonic counter used to invalidate in-flight streaming turns
  /// when the user resets or cancels. The audio tower in Gemma can
  /// stall for seconds on some clips and we don't want to surface
  /// tokens from an aborted turn in the next turn's slot.
  int _askVersion = 0;

  final StreamController<GatewaySnapshot> _snapshots =
      StreamController<GatewaySnapshot>.broadcast();

  /// Snapshot stream — the UI subscribes and re-renders on every event.
  Stream<GatewaySnapshot> get snapshots => _snapshots.stream;

  /// Synchronous view of the current snapshot. Useful for initial
  /// render before the first stream event arrives.
  GatewaySnapshot get current => _snapshot();

  /// Language Whisper detected for the most recent user utterance.
  String? get lastTurnLanguage => _lastTurnLanguage;

  // ------------------------------------------------------------------
  // Recording
  // ------------------------------------------------------------------

  /// Begin recording from the default microphone at 16 kHz mono WAV —
  /// the exact format Gemma's audio tower expects.
  Future<void> start() async {
    if (_isListening) return;
    if (!await _recorder.hasPermission()) {
      _lastError = 'Microphone permission denied.';
      _emit();
      return;
    }

    final cacheDir = await getTemporaryDirectory();
    final path =
        '${cacheDir.path}/turn_${DateTime.now().microsecondsSinceEpoch}.wav';
    _currentRecordingPath = path;

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          // Turn on echo cancellation + noise suppression where
          // available — emergency scenes are loud and the audio tower
          // is sensitive to background chatter.
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: path,
      );
      _isListening = true;
      _lastError = null;
      _emit();

      // Safety auto-stop so a forgotten mic doesn't eat battery or
      // bump into Gemma's 30 s audio window.
      _recordingTimeoutTimer?.cancel();
      _recordingTimeoutTimer = Timer(kMaxRecordingLength, () {
        if (_isListening) {
          stop().then((_) {});
        }
      });
    } catch (e) {
      _currentRecordingPath = null;
      _isListening = false;
      _lastError = 'Failed to start recording: $e';
      _emit();
    }
  }

  /// Stop recording and ask the model. Returns when the model's
  /// streamed reply has finished (use [snapshots] for live updates).
  Future<void> stop() async {
    if (!_isListening) return;
    _recordingTimeoutTimer?.cancel();
    _recordingTimeoutTimer = null;

    String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      _isListening = false;
      _currentRecordingPath = null;
      _lastError = 'Failed to stop recording: $e';
      _emit();
      return;
    }
    _isListening = false;
    _currentRecordingPath = null;
    _emit();

    path ??= _currentRecordingPath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists() || await file.length() < 1024) {
      _lastError = 'Recording too short — speak longer and tap again to send.';
      _emit();
      return;
    }

    try {
      await _askWavFile(path);
    } finally {
      try {
        await file.delete();
      } catch (_) {
        // best-effort cleanup
      }
    }
  }

  /// Cancel an in-flight recording without sending it to the model.
  Future<void> cancel() async {
    if (!_isListening) return;
    _recordingTimeoutTimer?.cancel();
    _recordingTimeoutTimer = null;
    try {
      await _recorder.cancel();
    } catch (_) {
      // best-effort
    }
    _isListening = false;
    _currentRecordingPath = null;
    _emit();
  }

  // ------------------------------------------------------------------
  // Model interaction
  // ------------------------------------------------------------------

  /// Ask the model with a pre-recorded WAV clip — used by the hands-
  /// free orchestrator, which owns its own recorder + VAD and hands us
  /// segmented audio rather than driving [start]/[stop].
  ///
  /// The bytes must be 16 kHz mono WAV (the same format Gemma's audio
  /// tower expects). Returns when the model's streamed reply has fully
  /// resolved (use [snapshots] for live updates). Cancellation is
  /// handled the same way as [stop] — bumping the ask version
  /// invalidates an in-flight reply.
  Future<void> askBytes(Uint8List wavBytes) async {
    if (wavBytes.length < 1024) {
      _lastError = 'Audio clip too short — try again.';
      _emit();
      return;
    }
    final cacheDir = await getTemporaryDirectory();
    final path =
        '${cacheDir.path}/hf_${DateTime.now().microsecondsSinceEpoch}.wav';
    final file = File(path);
    try {
      await file.writeAsBytes(wavBytes, flush: true);
      await _askWavFile(path);
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // best-effort
      }
    }
  }

  /// Max mono 16 kHz WAV payload (30 s × 32 kB/s ≈ 960 kB + 44 B header).
  static const int _kMaxWavBytes = 1024 * 1024;

  Future<void> _askWavFile(String wavPath, {int retryCount = 0}) async {
    final wavFile = File(wavPath);
    if (!await wavFile.exists()) {
      _lastError = 'Recording file missing — try again.';
      _emit();
      return;
    }
    final wavLen = await wavFile.length();
    if (wavLen < 1024) {
      _lastError = 'Recording too short — speak longer and tap again to send.';
      _emit();
      return;
    }
    if (wavLen > _kMaxWavBytes) {
      _lastError = 'Recording too long — keep clips under 30 seconds.';
      _emit();
      return;
    }

    final mine = ++_askVersion;
    _pendingCameraCall = null;
    final log = await SessionLog.ensureActive();
    await log.turnStart();

    _isTranscribing = true;
    _lastError = null;
    _emit();

    final wavBytes = await wavFile.readAsBytes();
    Map<String, dynamic> sttResult;
    try {
      sttResult = await _whisper.transcribeAudio(wavBytes);
    } catch (e, st) {
      debugPrint('AudioGateway: Whisper failed: $e\n$st');
      sttResult = {
        WhisperTranscriptionKeys.text: '',
        WhisperTranscriptionKeys.language: LanguageDetector.unknown,
        WhisperTranscriptionKeys.confidence: 0.0,
      };
    } finally {
      _isTranscribing = false;
    }

    if (mine != _askVersion) return;

    final transcript =
        (sttResult[WhisperTranscriptionKeys.text] as String? ?? '').trim();
    final detectedLang = LanguageDetector.normalizeForPipeline(
      sttResult[WhisperTranscriptionKeys.language] as String?,
    );
    final gemmaLang = detectedLang == LanguageDetector.unknown
        ? LanguageDetector.english
        : detectedLang;
    _lastTurnLanguage = gemmaLang;

    if (transcript.isEmpty) {
      _lastError = 'Could not transcribe speech — try again.';
      _emit();
      await log.userAudioTranscribed('(empty)');
      await log.turnEnd();
      return;
    }

    await log.userLanguageDetected(gemmaLang);
    await log.userAudioTranscribed(transcript);

    final conversation = await _ensureConversation(gemmaLang);
    if (conversation == null) return;

    final userDisplay = 'You said: $transcript';

    // Block protocol vector indexing while LiteRT owns the native runtime.
    _kb.setLiteRtInferenceActive(true);
    try {
      List<ProtocolHit> preHits = const [];
      try {
        preHits = await _kb.searchProtocols(transcript);
        final priorText = _priorModelTranscriptForRetrieval();
        if (priorText.length > 24) {
          preHits = _mergeProtocolHits(
            preHits,
            await _kb.searchProtocols(priorText),
          );
        }
      } catch (_) {
        preHits = const [];
      }
      final groundingPrefix = buildGroundingContext(
        preHits
            .take(3)
            .map((h) => '${h.title}: ${h.snippet}')
            .toList(),
        languageCode: gemmaLang,
      );
      final langReminder = userTurnLanguageReminder(gemmaLang);
      final userPrompt = groundingPrefix.isEmpty
          ? '${langReminder}The responder said:\n"$transcript"\n\n'
              'Answer their first-aid question per the system rules.'
          : '$langReminder$groundingPrefix'
              'The responder said:\n"$transcript"\n\n'
              'Use CONTEXT when relevant.';

      _turns.add(ConversationTurn(
        role: TurnRole.user,
        text: userDisplay,
        isStreaming: false,
        detectedLanguage: gemmaLang,
      ));
      _turns.add(ConversationTurn(
        role: TurnRole.model,
        text: '',
        isStreaming: true,
      ));
      _isThinking = true;
      _lastError = null;
      _emit();

      final modelIndex = _turns.length - 1;

      final buffer = StringBuffer();
      final parser = ToolCallStreamParser();
      final dispatchedToolIds = <String>[];
      final firedPayloads = <String>{};

      // Begin streaming TTS for this turn (sentences spoken as they arrive).
      streamingTts?.begin(language: gemmaLang);

      await log.gemmaStart();
      try {
        final stream = conversation.sendMultimodalMessageStream([
          LiteLmContent.text(userPrompt),
        ]);

        await for (final chunk in stream) {
          if (mine != _askVersion) {
            streamingTts?.cancel();
            return;
          }
          if (chunk.text.isEmpty) continue;

          final parsed = parser.feed(chunk.text);
          if (parsed.cleanedText.isNotEmpty) {
            buffer.write(parsed.cleanedText);
            _turns[modelIndex] = _turns[modelIndex].copyWith(
              text: buffer.toString(),
              isStreaming: true,
            );
            _emit();

            // Feed streaming TTS without awaiting playback.
            unawaited(streamingTts?.onToken(parsed.cleanedText));
          }
          for (final call in parsed.calls) {
            await _dispatchTool(
              call,
              firedPayloads,
              dispatchedToolIds,
              modelIndex,
            );
          }
        }
        // Gemma done — unlock mic immediately; TTS may still be playing.
        _turns[modelIndex] = _turns[modelIndex].copyWith(
          text: buffer.toString(),
          isStreaming: false,
        );
        _isThinking = false;
        _emit();
        // #region agent log
        print('[DBG-b37fdb] H9 GEMMA_STREAM_END: isThinking=false sentencesQueued=${streamingTts?.sentencesQueued ?? 0}');
        // #endregion
        unawaited(streamingTts?.finish());
      } catch (e, st) {
        streamingTts?.cancel();
        if (mine != _askVersion) return;
        debugPrint('AudioGateway: LiteRT audio turn failed: $e\n$st');
        // #region agent log
        print('[DBG-b37fdb] H7 LiteRT CATCH: retryCount=$retryCount recoverable=${_isRecoverableLiteRtFailure(e)} error=$e');
        // #endregion
        if (retryCount < 2 && _isRecoverableLiteRtFailure(e)) {
          _conversationBroken = true;
          await _disposeConversation();
          if (retryCount >= 1) {
            try {
              // #region agent log
              print('[DBG-b37fdb] H7 recreateAfterNativeFault ATTEMPT retry=$retryCount');
              // #endregion
              await _engine.recreateAfterNativeFault();
              // #region agent log
              print('[DBG-b37fdb] H7 recreateAfterNativeFault OK engine=${_engine.engine != null}');
              // #endregion
            } catch (recreateErr) {
              // #region agent log
              print('[DBG-b37fdb] H7 recreateAfterNativeFault FAILED: $recreateErr');
              // #endregion
              debugPrint(
                'AudioGateway: engine recreate failed: $recreateErr',
              );
            }
          }
          if (_turns.length >= 2) {
            _turns.removeRange(_turns.length - 2, _turns.length);
          }
          _isThinking = false;
          _emit();
          await Future<void>.delayed(
            Duration(milliseconds: 600 + retryCount * 900),
          );
          return _askWavFile(wavPath, retryCount: retryCount + 1);
        }
        _lastError = _friendlyModelError(e);
        _conversationBroken = true;
        _turns[modelIndex] = _turns[modelIndex].copyWith(
          text: buffer.isEmpty
              ? '(model error — please try again)'
              : buffer.toString(),
          isStreaming: false,
        );
        _isThinking = false;
        _emit();
        await log.gemmaResponse('(error) $e');
        await log.turnEnd();
        return;
      }

      if (mine != _askVersion) return;

      final flushed = parser.flush();
      if (flushed.cleanedText.isNotEmpty) {
        buffer.write(flushed.cleanedText);
      }
      for (final call in flushed.calls) {
        await _dispatchTool(
          call,
          firedPayloads,
          dispatchedToolIds,
          modelIndex,
        );
      }

      final cameraCall = _pendingCameraCall;
      _pendingCameraCall = null;
      if (cameraCall != null && mine == _askVersion && _cameraHost != null) {
        final visualReply = await _runCameraVisualTurn(
          call: cameraCall,
          transcript: transcript,
          gemmaLang: gemmaLang,
          langReminder: langReminder,
          groundingPrefix: groundingPrefix,
          preHits: preHits,
          mine: mine,
          modelIndex: modelIndex,
          conversation: conversation,
          firedPayloads: firedPayloads,
          dispatchedToolIds: dispatchedToolIds,
        );
        if (visualReply != null) {
          buffer
            ..clear()
            ..write(visualReply);
        }
      }

      // Recover tools from unclosed / post-prose tags and strip them
      // from the transcript before KB search, logging, and TTS.
      var replyText = buffer.toString();
      for (final call in ToolCallExtractor.extractFromText(replyText)) {
        await _dispatchTool(
          call,
          firedPayloads,
          dispatchedToolIds,
          modelIndex,
        );
      }
      replyText = ToolCallExtractor.stripFromText(replyText);
      buffer
        ..clear()
        ..write(replyText);

      // KB search after LiteRT releases the inference gate.
      _kb.setLiteRtInferenceActive(false);
      List<ProtocolHit> postHits = const [];
      try {
        postHits = await _kb.searchProtocols(replyText);
      } catch (_) {
        postHits = const [];
      }
      final hits = _mergeProtocolHits(preHits, postHits);

      await log.gemmaResponse(replyText);
      await log.sourcesFromHits(hits);
      await _maybeLogTriage(log, replyText);

      final warnings = <String>[];
      final citations = <KbCitation>[];
      var grounded = false;
      if (hits.isNotEmpty) {
        grounded = true;
        for (final h in hits) {
          citations.add(h.citation);
        }
      } else {
        warnings.add('Answer not verified against local KB.');
      }

      _turns[modelIndex] = _turns[modelIndex].copyWith(
        text: _ensureDisclaimer(replyText, gemmaLang),
        isStreaming: false,
        grounded: grounded,
        citations: citations,
        protocols: hits,
        warnings: warnings,
        toolInvocationIds: List<String>.unmodifiable(dispatchedToolIds),
      );
      _isThinking = false;
      _emit();
      await log.turnEnd();
      // #region agent log
      print('[DBG-b37fdb] H6 TURN COMPLETE: engine=${_engine.engine != null}, initialized=${_engine.isInitialized}');
      // #endregion

      final kb = _kb;
      if (kb is FileMedicalKb) {
        kb.scheduleProtocolIndexWarmAfterFirstAudioTurn();
      }
    } finally {
      _kb.setLiteRtInferenceActive(false);
    }
  }

  Future<void> _maybeLogTriage(SessionLog log, String reply) async {
    final lower = reply.toLowerCase();
    final signs = <String>[];
    for (final kw in <String>[
      'unconscious',
      'not breathing',
      'bleeding',
      'choking',
      'chest pain',
      'stroke',
      'seizure',
      'anaphylaxis',
    ]) {
      if (lower.contains(kw)) signs.add(kw);
    }
    try {
      final rule = await _kb.lookupTriageRule(
        observedSigns: signs,
        visibleBleeding: lower.contains('bleed'),
        responsiveAppearing:
            lower.contains('unresponsive') || lower.contains('unconscious')
                ? false
                : null,
      );
      if (rule != null) {
        await log.triage(rule.tier);
      }
    } catch (_) {
      // best-effort
    }
  }

  /// LiteRT INTERNAL / OpenCL failures are often recoverable with a
  /// fresh conversation or a full engine recreate (MediaTek GPUs).
  bool _isRecoverableLiteRtFailure(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('internal') ||
        s.contains('failed to invoke') ||
        s.contains('compiled model') ||
        s.contains('stream_error') ||
        s.contains('message_error') ||
        s.contains('engine_error') ||
        s.contains('clenqueuereadbuffer') ||
        s.contains('opencl') ||
        s.contains('litertlmjni') ||
        s.contains('status code: 2');
  }

  String _friendlyModelError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('clenqueuereadbuffer') ||
        s.contains('opencl') ||
        s.contains('stream_error') ||
        s.contains('litertlmjni')) {
      return 'On-device model hit a GPU error. Tap RESET, then try '
          'again with a shorter question.';
    }
    return 'Model failed: $e';
  }

  /// Dispatch [call] through [_tools], dedup against [firedPayloads]
  /// (so a stream-time tag and the post-parse fallback don't fire the
  /// same call twice), append the resulting invocation id to
  /// [dispatchedToolIds], and reflect it on the in-flight model turn
  /// at [modelIndex]. Errors are logged and swallowed — a tool failure
  /// must never break the streaming reply.
  Future<void> _dispatchTool(
    ToolCall call,
    Set<String> firedPayloads,
    List<String> dispatchedToolIds,
    int modelIndex,
  ) async {
    // Dedup signature: tool name + canonical args. Two consecutive
    // identical calls (e.g. parsed mid-stream AND caught again by the
    // post-prose regex) collapse to one side-effect.
    final sig = '${call.name}|${call.args}';
    if (!firedPayloads.add(sig)) return;

    if (call.name == 'request_camera_mode') {
      _pendingCameraCall = call;
      await SessionLog.instance?.cameraModalRequested(_cameraLabelFromCall(call));
      return;
    }

    try {
      final inv = await _tools.execute(call);
      dispatchedToolIds.add(inv.id);
      // Reflect the new tool id on the current model turn so the
      // transcript card can render it as soon as the side-effect
      // starts, instead of waiting for the stream to end.
      if (modelIndex >= 0 && modelIndex < _turns.length) {
        _turns[modelIndex] = _turns[modelIndex].copyWith(
          toolInvocationIds:
              List<String>.unmodifiable(dispatchedToolIds),
        );
        _emit();
      }
    } catch (e, st) {
      debugPrint('AudioGateway: tool dispatch failed: $e\n$st');
    }
  }

  String _cameraLabelFromCall(ToolCall call) {
    final label = call.args['label'];
    if (label is String && label.trim().isNotEmpty) {
      return label.trim();
    }
    return 'Visual assessment';
  }

  /// Opens the agentic camera modal and streams a multimodal Gemma
  /// reply into [modelIndex]. Returns the final reply text, or `null`
  /// if the responder cancelled (pre-camera spoken text is kept).
  Future<String?> _runCameraVisualTurn({
    required ToolCall call,
    required String transcript,
    required String gemmaLang,
    required String langReminder,
    required String groundingPrefix,
    required List<ProtocolHit> preHits,
    required int mine,
    required int modelIndex,
    required LiteLmConversation conversation,
    required Set<String> firedPayloads,
    required List<String> dispatchedToolIds,
  }) async {
    final host = _cameraHost;
    if (host == null) return null;

    await _onBeforeCameraModal?.call();

    final label = _cameraLabelFromCall(call);
    final imageBytes = await host.capture(label: label);
    if (mine != _askVersion) return null;

    if (imageBytes == null) {
      await SessionLog.instance?.cameraCancelled();
      return null;
    }

    await SessionLog.instance?.cameraImageCaptured(byteLength: imageBytes.length);
    await SessionLog.instance?.cameraImageInjected();

    final priorText = _turns[modelIndex].text;
    _turns[modelIndex] = _turns[modelIndex].copyWith(
      text: priorText.trim().isEmpty
          ? 'Reviewing photo…'
          : '${priorText.trim()}\n\nReviewing photo…',
      isStreaming: true,
    );
    _emit();

    final visualPrompt = buildVisualAssessmentUserPrompt(
      transcript: transcript,
      assessmentLabel: label,
      langReminder: langReminder,
      groundingPrefix: groundingPrefix,
    );

    for (var i = _turns.length - 1; i >= 0; i--) {
      if (_turns[i].role != TurnRole.user) continue;
      final base = _turns[i].text.trim();
      _turns[i] = _turns[i].copyWith(
        text: base.contains('(Photo attached)')
            ? base
            : '$base\n(Photo attached)',
      );
      break;
    }
    _emit();

    final buffer = StringBuffer();
    final parser = ToolCallStreamParser();
    final sessionLog = await SessionLog.ensureActive();
    await sessionLog.gemmaStart();
    try {
      final stream = conversation.sendMultimodalMessageStream([
        LiteLmContent.text(visualPrompt),
        LiteLmContent.imageBytes(imageBytes),
      ]);

      await for (final chunk in stream) {
        if (mine != _askVersion) return null;
        if (chunk.text.isEmpty) continue;

        final parsed = parser.feed(chunk.text);
        if (parsed.cleanedText.isNotEmpty) {
          buffer.write(parsed.cleanedText);
          _turns[modelIndex] = _turns[modelIndex].copyWith(
            text: buffer.toString(),
            isStreaming: true,
          );
          _emit();
        }
        for (final toolCall in parsed.calls) {
          await _dispatchTool(
            toolCall,
            firedPayloads,
            dispatchedToolIds,
            modelIndex,
          );
        }
      }
    } catch (e, st) {
      if (mine != _askVersion) return null;
      debugPrint('AudioGateway: visual turn failed: $e\n$st');
      _lastError = _friendlyModelError(e);
      return buffer.isEmpty
          ? '(Could not analyze the photo — try describing again.)'
          : buffer.toString();
    }

    if (mine != _askVersion) return null;

    final flushed = parser.flush();
    if (flushed.cleanedText.isNotEmpty) {
      buffer.write(flushed.cleanedText);
    }
    for (final toolCall in flushed.calls) {
      await _dispatchTool(
        toolCall,
        firedPayloads,
        dispatchedToolIds,
        modelIndex,
      );
    }

    var replyText = buffer.toString();
    for (final toolCall in ToolCallExtractor.extractFromText(replyText)) {
      await _dispatchTool(
        toolCall,
        firedPayloads,
        dispatchedToolIds,
        modelIndex,
      );
    }
    replyText = ToolCallExtractor.stripFromText(replyText);
    return replyText.trim().isEmpty ? null : replyText;
  }

  /// Tear down the current conversation and start a fresh one. Full
  /// multi-turn mode — the responder explicitly invokes this from the
  /// `[RESET]` control when switching scenes or patients.
  Future<void> reset() async {
    _askVersion++;
    _isThinking = false;
    _isTranscribing = false;
    if (_isListening) {
      await cancel();
    }
    // Tear down any agentic tools the prior conversation kicked off
    // (CPR cadence, breathing pacer, medical timers). A stale CPR
    // metronome buzzing through a fresh ASK turn is a guaranteed
    // user-confidence kill, so this stops first thing.
    await _tools.stopAll();
    await _disposeConversation();
    _turns
      ..clear()
      ..add(ConversationTurn(
        role: TurnRole.system,
        text: 'Conversation reset. Ask a new first-aid question.',
      ));
    _lastError = null;
    _emit();
  }

  /// Release the native LiteRT **conversation session** so another
  /// subsystem (vision) can call [LiteLmEngine.createConversation].
  ///
  /// LiteRT-LM only allows one conversation per engine. This hook was
  /// used when camera ran a separate vision pipeline; the agentic
  /// camera modal now shares the ASK conversation instead.
  ///
  /// Does **not** clear the on-screen transcript — only the native
  /// session. The next mic press builds a new conversation (multi-turn
  /// context across the vision hand-off is intentionally dropped).
  Future<void> suspendForExternalInference() async {
    _askVersion++;
    _recordingTimeoutTimer?.cancel();
    _recordingTimeoutTimer = null;

    if (_isListening) {
      try {
        await _recorder.cancel();
      } catch (_) {
        // best-effort
      }
      _isListening = false;
      _currentRecordingPath = null;
    }

    if (_isThinking) {
      for (var i = _turns.length - 1; i >= 0; i--) {
        final t = _turns[i];
        if (t.role == TurnRole.model && t.isStreaming) {
          _turns[i] = t.copyWith(
            text: t.text.trim().isEmpty
                ? '(interrupted — camera in use)'
                : '${t.text}\n(interrupted — camera in use)',
            isStreaming: false,
          );
          break;
        }
      }
      _isThinking = false;
    }

    // Stop any running tool side-effects too — the responder is about
    // to take a photo and a phone vibrating in their hand at 110 BPM
    // makes that worse. The transcript record of the tool firing is
    // still visible in the prior turn card.
    await _tools.stopAll();
    await _disposeConversation();
    _lastError = null;
    _emit();
  }

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  /// Add TTS fallback banner to the latest completed model turn.
  void annotateLastModelTurnTtsFallback(String banner) {
    for (var i = _turns.length - 1; i >= 0; i--) {
      final t = _turns[i];
      if (t.role != TurnRole.model || t.isStreaming) continue;
      if (t.warnings.contains(banner)) return;
      _turns[i] = t.copyWith(
        warnings: <String>[...t.warnings, banner],
      );
      _emit();
      return;
    }
  }

  Future<LiteLmConversation?> _ensureConversation(String languageCode) async {
    // #region agent log
    print('[DBG-b37fdb] H6 _ensureConversation: engine=${_engine.engine != null}, initialized=${_engine.isInitialized}, convBroken=$_conversationBroken, conv=${_conversation != null}');
    // #endregion
    final engine = _engine.engine;
    if (engine == null) {
      // #region agent log
      print('[DBG-b37fdb] H6 ENGINE IS NULL — Model engine not initialized');
      // #endregion
      _lastError = 'Model engine not initialized.';
      _emit();
      return null;
    }
    if (_conversationBroken) {
      await _disposeConversation();
    }
    final lang = LanguageDetector.normalizeForPipeline(languageCode);
    final effectiveLang =
        lang == LanguageDetector.unknown ? LanguageDetector.english : lang;

    if (_conversation != null && _conversationLanguage != effectiveLang) {
      await _disposeConversation();
    }
    if (_conversation != null) return _conversation;

    try {
      _conversation = await engine.createConversation(
        LiteLmConversationConfig(
          systemInstruction: buildFirstAidSystemPrompt(effectiveLang),
          samplerConfig: const LiteLmSamplerConfig(
            temperature: 0.3,
            topK: 40,
            topP: 0.95,
          ),
        ),
      );
      _conversationLanguage = effectiveLang;
      _conversationBroken = false;
      return _conversation;
    } catch (e) {
      _lastError = 'Failed to start conversation: $e';
      _emit();
      return null;
    }
  }

  Future<void> _disposeConversation() async {
    final c = _conversation;
    _conversation = null;
    _conversationLanguage = null;
    _conversationBroken = false;
    if (c != null) {
      try {
        await c.dispose();
      } catch (_) {
        // best-effort
      }
    }
  }

  Future<void> dispose() async {
    _askVersion++;
    _recordingTimeoutTimer?.cancel();
    _recordingTimeoutTimer = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.cancel();
      }
    } catch (_) {
      // best-effort
    }
    try {
      await _recorder.dispose();
    } catch (_) {
      // best-effort
    }
    await _disposeConversation();
    await _snapshots.close();
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  /// Completed model lines only — used to retrieve protocols before a
  /// follow-up audio turn without waiting for ASR on the new clip.
  String _priorModelTranscriptForRetrieval() {
    final buf = StringBuffer();
    for (final t in _turns) {
      if (t.role != TurnRole.model) continue;
      if (t.isStreaming) continue;
      final s = t.text.trim();
      if (s.isEmpty) continue;
      buf.writeln(s);
    }
    return buf.toString().trim();
  }

  /// Preserve pre-turn retrieval hits ahead of post-reply search, de-duped.
  List<ProtocolHit> _mergeProtocolHits(
    List<ProtocolHit> a,
    List<ProtocolHit> b,
  ) {
    final seen = <String>{};
    final out = <ProtocolHit>[];
    for (final h in [...a, ...b]) {
      final id = h.citation.sourceId;
      if (id.isEmpty) continue;
      if (!seen.add(id)) continue;
      out.add(h);
    }
    return out;
  }

  void _emit() {
    if (_snapshots.isClosed) return;
    _snapshots.add(_snapshot());
  }

  GatewaySnapshot _snapshot() {
    return GatewaySnapshot(
      turns: List<ConversationTurn>.unmodifiable(_turns),
      isListening: _isListening,
      isThinking: _isThinking,
      isTranscribing: _isTranscribing,
      error: _lastError,
    );
  }

  String _ensureDisclaimer(String reply, String languageCode) {
    final clean = reply.trim();
    final disclaimer = nonDiagnosticDisclaimerFor(languageCode);
    if (clean.isEmpty) return disclaimer;
    if (clean.contains('not a medical diagnosis') ||
        clean.contains('طبی تشخیص نہیں')) {
      return clean;
    }
    return '$clean\n\n$disclaimer';
  }
}
