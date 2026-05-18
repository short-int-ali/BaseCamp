import 'dart:async';

import 'package:flutter/material.dart';

import '../database/medical_kb.dart';
import '../modules/audio/audio_gateway.dart';
import '../modules/audio/multilingual_tts.dart';
import '../modules/hands_free/hands_free_orchestrator.dart';
import '../modules/tools/breathing_pacer_tool.dart';
import '../modules/tools/cpr_cadence_tool.dart';
import '../modules/tools/medical_timer_tool.dart';
import '../modules/tools/tool_dispatcher.dart';
import '../constants/disclaimers.dart';
import '../services/camera_capture_host.dart';
import '../services/model_engine.dart';
import '../services/app_permissions.dart';
import '../services/session_log.dart';
import '../services/whisper_transcriber.dart';
import '../theme/emergency_theme.dart';
import 'audio_ui.dart';
import 'components/base_camp_components.dart';

/// App shell. Owns the shared [ModelEngine] boot gate, [AudioGateway],
/// [MultilingualTTS], and [HandsFreeOrchestrator]. ASK mode is the only
/// primary screen; the camera is an agentic modal opened by Gemma.
class EmergencyUI extends StatefulWidget {
  const EmergencyUI({
    super.key,
    required this.engine,
    required this.kb,
  });

  final ModelEngine engine;
  final MedicalKb kb;

  @override
  State<EmergencyUI> createState() => _EmergencyUIState();
}

class _EmergencyUIState extends State<EmergencyUI> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  Future<void>? _engineInitFuture;
  String? _fatalError;

  late final CameraCaptureHost _cameraHost;
  late final MultilingualTTS _tts;
  late final WhisperTranscriber _whisper;
  late final AudioGateway _gateway;
  late final ToolDispatcher _tools;
  late final HandsFreeOrchestrator _handsFree;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(requestAppPermissions());
    });
    unawaited(SessionLog.start());

    _cameraHost = CameraCaptureHost(_navigatorKey);
    _tts = MultilingualTTS();
    _tools = ToolDispatcher(
      handlers: <String, ToolHandler>{
        'cpr_cadence': CprCadenceTool(),
        'breathing_pacer': BreathingPacerTool(),
        'medical_timer': MedicalTimerTool(),
      },
    );
    _whisper = WhisperTranscriber();
    _gateway = AudioGateway(
      engine: widget.engine,
      kb: widget.kb,
      tools: _tools,
      whisper: _whisper,
      cameraHost: _cameraHost,
      onBeforeCameraModal: () async {
        await _handsFree.disarm();
      },
    );
    _handsFree = HandsFreeOrchestrator(
      gateway: _gateway,
      tts: _tts,
      whisper: _whisper,
    );
    _engineInitFuture = _bootEngine();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(SessionLog.endIfActive(reason: 'app_exit'));
    _handsFree.dispose();
    _gateway.dispose();
    _whisper.dispose();
    _tts.dispose();
    _tools.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(SessionLog.endIfActive(reason: 'detached'));
    }
  }

  Future<void> _bootEngine() async {
    try {
      await widget.engine.create();
    } on ModelMissingException catch (e) {
      if (!mounted) return;
      final locations = e.searchedPaths.map((p) => '• $p').join('\n');
      setState(() {
        _fatalError =
            'Model bundle not found.\n\n'
            'Searched:\n$locations\n\n'
            'Drop or `adb push` the LiteRT-LM file to one of those '
            'locations and relaunch.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fatalError = 'Failed to load on-device model:\n$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_fatalError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: EmergencyTheme.build(),
        home: _FatalErrorGate(message: _fatalError!),
      );
    }

    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: EmergencyTheme.build(),
      home: AudioUI(
        gateway: _gateway,
        tts: _tts,
        tools: _tools,
        handsFree: _handsFree,
        engineInitFuture: _engineInitFuture,
      ),
    );
  }
}

class _FatalErrorGate extends StatelessWidget {
  const _FatalErrorGate({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EmergencyPalette.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: EmergencyPalette.emergencyRed.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.warning_amber_rounded,
                  size: 40,
                  color: EmergencyPalette.emergencyRed,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Cannot start',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              BaseCampSurfaceCard(
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const Spacer(),
              BaseCampDisclaimerBanner(text: kNonDiagnosticDisclaimer),
            ],
          ),
        ),
      ),
    );
  }
}
