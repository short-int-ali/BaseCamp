import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/disclaimers.dart';
import '../modules/vision/image_preprocess.dart';
import '../theme/emergency_theme.dart';
import 'components/base_camp_components.dart';

/// Fullscreen modal for Gemma-driven visual assessment during ASK mode.
Future<Uint8List?> showCameraAssessmentModal(
  BuildContext context, {
  required String label,
}) {
  return Navigator.of(context).push<Uint8List?>(
    PageRouteBuilder<Uint8List?>(
      opaque: true,
      barrierDismissible: false,
      pageBuilder: (ctx, _, __) => _CameraAssessmentModal(label: label),
      transitionsBuilder: (_, animation, __, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    ),
  );
}

class _CameraAssessmentModal extends StatefulWidget {
  const _CameraAssessmentModal({required this.label});

  final String label;

  @override
  State<_CameraAssessmentModal> createState() => _CameraAssessmentModalState();
}

class _CameraAssessmentModalState extends State<_CameraAssessmentModal>
    with WidgetsBindingObserver {
  CameraController? _camera;
  Future<void>? _initFuture;
  bool _capturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initFuture = _bootCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _camera?.dispose();
      _camera = null;
    } else if (state == AppLifecycleState.resumed) {
      _initFuture = _bootCamera();
      setState(() {});
    }
  }

  Future<void> _bootCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw StateError('No cameras available.');
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Camera unavailable: $e');
    }
  }

  void _closeWithoutImage() {
    Navigator.of(context).pop(null);
  }

  Future<void> _onCapture() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _capturing) return;

    setState(() => _capturing = true);
    await HapticFeedback.mediumImpact();

    try {
      final picture = await camera.takePicture();
      final raw = await picture.readAsBytes();
      await camera.dispose();
      _camera = null;

      final processed = preprocessJpegForVision(raw);
      if (!mounted) return;
      Navigator.of(context).pop(processed);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _capturing = false;
        _error = 'Capture failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EmergencyPalette.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                widget.label.trim().isEmpty
                    ? 'Visual assessment'
                    : widget.label.trim(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            const BaseCampHeaderAccent(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.circular(EmergencyPalette.radiusLg),
                  child: _error != null
                      ? _errorPane()
                      : _preview(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: BaseCampCircularAction(
                size: 88,
                busy: _capturing,
                color: _capturing
                    ? EmergencyPalette.emergencyRedDeep
                    : EmergencyPalette.emergencyRed,
                icon: Icons.camera_alt_rounded,
                onTap: _error == null ? _onCapture : null,
                semanticsLabel:
                    _capturing ? 'Capturing' : 'Capture photo',
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _capturing ? null : _closeWithoutImage,
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _capturing ? null : _closeWithoutImage,
                      child: const Text('Back'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const BaseCampDisclaimerBanner(text: kNonDiagnosticDisclaimer),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _errorPane() {
    return Container(
      color: EmergencyPalette.surfaceElevated,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Text(
        _error!,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  Widget _preview() {
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (ctx, snap) {
        final camera = _camera;
        if (camera == null ||
            snap.connectionState != ConnectionState.done ||
            !camera.value.isInitialized) {
          return Container(
            color: EmergencyPalette.surfaceElevated,
            alignment: Alignment.center,
            child: const CircularProgressIndicator(
              color: EmergencyPalette.emergencyRed,
              strokeWidth: 2.5,
            ),
          );
        }
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: camera.value.previewSize?.height ?? 1,
              height: camera.value.previewSize?.width ?? 1,
              child: CameraPreview(camera),
            ),
          ),
        );
      },
    );
  }
}
