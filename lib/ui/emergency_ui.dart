import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../modules/vision/prompts.dart';
import '../modules/vision/vision_mode.dart';
import '../modules/vision/vision_processor.dart';
import '../modules/vision/vision_result.dart';
import '../theme/emergency_theme.dart';

/// The root screen. Owns the camera, the selected [VisionMode], and
/// the lifecycle of a single [VisionProcessor].
class EmergencyUI extends StatefulWidget {
  const EmergencyUI({
    super.key,
    required this.processor,
  });

  final VisionProcessor processor;

  @override
  State<EmergencyUI> createState() => _EmergencyUIState();
}

class _EmergencyUIState extends State<EmergencyUI>
    with WidgetsBindingObserver {
  CameraController? _camera;
  Future<void>? _cameraInitFuture;
  Future<void>? _processorInitFuture;

  VisionMode _mode = VisionMode.patients;
  bool _inferring = false;
  String? _fatalError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _processorInitFuture = _bootProcessor();
    _cameraInitFuture = _bootCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      camera.dispose();
    } else if (state == AppLifecycleState.resumed) {
      setState(() {
        _cameraInitFuture = _bootCamera();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _bootProcessor() async {
    try {
      await widget.processor.initialize();
    } on ModelMissingException catch (e) {
      if (mounted) {
        setState(() {
          _fatalError =
              'Model bundle not found.\n\nExpected at:\n${e.expectedPath}\n\n'
              'Drop the LiteRT-LM file there and relaunch.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _fatalError = 'Failed to load on-device model:\n$e';
        });
      }
    }
  }

  Future<void> _bootCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw StateError('No cameras available on this device.');
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
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
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _fatalError = 'Camera unavailable:\n$e';
        });
      }
    }
  }

  Future<void> _onShutter() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    if (_inferring) return;

    setState(() => _inferring = true);
    await HapticFeedback.mediumImpact();

    try {
      final picture = await camera.takePicture();
      final bytes = await picture.readAsBytes();
      final result = await widget.processor.analyze(
        jpegBytes: bytes,
        mode: _mode,
      );
      if (!mounted) return;
      await _showResult(result);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: EmergencyPalette.emergencyRedDeep,
          content: Text('Analysis failed: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _inferring = false);
    }
  }

  Future<void> _showResult(VisionResult result) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ResultSheet(result: result),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_fatalError != null) {
      return _FatalErrorGate(message: _fatalError!);
    }
    return Scaffold(
      backgroundColor: EmergencyPalette.background,
      appBar: AppBar(
        title: const Text('BASE CAMP'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FutureBuilder<void>(
              future: _processorInitFuture,
              builder: (ctx, snap) {
                final loaded =
                    snap.connectionState == ConnectionState.done &&
                        snap.hasError == false;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.memory,
                      size: 18,
                      color: loaded
                          ? EmergencyPalette.triageGreen
                          : EmergencyPalette.onSurfaceMuted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      loaded ? 'MODEL' : 'LOADING',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                        color: loaded
                            ? EmergencyPalette.triageGreen
                            : EmergencyPalette.onSurfaceMuted,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: _cameraPreview(),
              ),
            ),
          ),
          _ModeSelector(
            selected: _mode,
            onChanged: _inferring
                ? null
                : (m) => setState(() => _mode = m),
          ),
          const SizedBox(height: 12),
          _ShutterButton(
            busy: _inferring,
            onPressed: _onShutter,
          ),
          const SizedBox(height: 12),
          const _DisclaimerBanner(),
        ],
      ),
    );
  }

  Widget _cameraPreview() {
    return FutureBuilder<void>(
      future: _cameraInitFuture,
      builder: (ctx, snap) {
        final camera = _camera;
        if (camera == null ||
            snap.connectionState != ConnectionState.done ||
            !camera.value.isInitialized) {
          return Container(
            color: EmergencyPalette.surface,
            alignment: Alignment.center,
            child: const CircularProgressIndicator(
              color: EmergencyPalette.emergencyRed,
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

/// Full-screen error/gate shown when either the model bundle is
/// missing or the camera cannot initialize. Satisfies the "assets
/// verified on first boot" requirement.
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
              const Icon(
                Icons.warning_amber_rounded,
                size: 56,
                color: EmergencyPalette.emergencyRed,
              ),
              const SizedBox(height: 16),
              const Text(
                'BASE CAMP CANNOT START',
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
              const _DisclaimerBanner(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.selected, required this.onChanged});
  final VisionMode selected;
  final ValueChanged<VisionMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final mode in VisionMode.values) ...[
            Expanded(
              child: _ModeButton(
                mode: mode,
                selected: mode == selected,
                onPressed: onChanged == null ? null : () => onChanged!(mode),
              ),
            ),
            if (mode != VisionMode.values.last) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.mode,
    required this.selected,
    required this.onPressed,
  });

  final VisionMode mode;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return FilledButton(
        onPressed: onPressed,
        child: Text(mode.label),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      child: Text(mode.label),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: !busy,
      label: busy ? 'Analyzing' : 'Capture and analyze',
      child: GestureDetector(
        onTap: busy ? null : onPressed,
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: busy
                ? EmergencyPalette.emergencyRedDeep
                : EmergencyPalette.emergencyRed,
            border: Border.all(
              color: EmergencyPalette.onSurface,
              width: 4,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: busy
              ? const SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    strokeWidth: 3.5,
                    color: EmergencyPalette.onSurface,
                  ),
                )
              : const Icon(
                  Icons.camera_alt,
                  color: EmergencyPalette.onSurface,
                  size: 40,
                ),
        ),
      ),
    );
  }
}

class _DisclaimerBanner extends StatelessWidget {
  const _DisclaimerBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      color: EmergencyPalette.emergencyRedDeep,
      child: const Text(
        kNonDiagnosticDisclaimer,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: EmergencyPalette.onSurface,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _ResultSheet extends StatelessWidget {
  const _ResultSheet({required this.result});
  final VisionResult result;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 8,
          bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  result.mode.label,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.3,
                    color: EmergencyPalette.onSurface,
                  ),
                ),
                const SizedBox(width: 12),
                if (result.triage != null) _TriageChip(tier: result.triage!),
                const Spacer(),
                _GroundingChip(grounded: result.groundedByRag),
              ],
            ),
            const SizedBox(height: 16),
            if (result.warnings.isNotEmpty) ...[
              for (final w in result.warnings) ...[
                _WarningBanner(text: w),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8),
            ],
            Text(
              result.summary,
              style: const TextStyle(
                fontSize: 16,
                height: 1.4,
                color: EmergencyPalette.onSurface,
              ),
            ),
            if (result.citations.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'LOCAL KB CITATIONS',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: EmergencyPalette.onSurfaceMuted,
                ),
              ),
              const SizedBox(height: 8),
              for (final c in result.citations) ...[
                Text(
                  '• ${c.snippet}  (${c.sourceId})',
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: EmergencyPalette.onSurfaceMuted,
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('DISMISS'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TriageChip extends StatelessWidget {
  const _TriageChip({required this.tier});
  final TriageTier tier;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    switch (tier) {
      case TriageTier.red:
        bg = EmergencyPalette.emergencyRed;
        fg = EmergencyPalette.onSurface;
        break;
      case TriageTier.yellow:
        bg = EmergencyPalette.triageYellow;
        fg = EmergencyPalette.background;
        break;
      case TriageTier.green:
        bg = EmergencyPalette.triageGreen;
        fg = EmergencyPalette.background;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        tier.label,
        style: TextStyle(
          color: fg,
          fontSize: 13,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _GroundingChip extends StatelessWidget {
  const _GroundingChip({required this.grounded});
  final bool grounded;

  @override
  Widget build(BuildContext context) {
    final color = grounded
        ? EmergencyPalette.triageGreen
        : EmergencyPalette.triageYellow;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          grounded ? Icons.verified : Icons.help_outline,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 4),
        Text(
          grounded ? 'KB VERIFIED' : 'NOT VERIFIED',
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
      ],
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: EmergencyPalette.emergencyRedDeep,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: EmergencyPalette.onSurface,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: EmergencyPalette.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
