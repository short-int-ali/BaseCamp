import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ui/camera_assessment_modal.dart';

/// Presents the agentic camera modal from anywhere in the app tree.
///
/// Wired once from [EmergencyUI] via a root [NavigatorState] key so
/// [AudioGateway] can await a capture without holding a [BuildContext].
class CameraCaptureHost {
  CameraCaptureHost(this._navigatorKey);

  final GlobalKey<NavigatorState> _navigatorKey;

  /// Fullscreen capture flow. Returns preprocessed JPEG bytes, or `null`
  /// if the responder cancelled or navigated back without a photo.
  Future<Uint8List?> capture({required String label}) async {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) return null;
    return showCameraAssessmentModal(
      ctx,
      label: label,
    );
  }
}
