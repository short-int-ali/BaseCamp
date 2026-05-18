import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

bool _bindingsReady = false;

/// Must run once before any `sherpa_onnx` native object (KWS, VAD, etc.).
///
/// Previously lived in Piper [SpeechSynth]; system TTS no longer loads
/// sherpa, so hands-free owns this call.
void ensureSherpaOnnxInitialized() {
  if (_bindingsReady) return;
  sherpa_onnx.initBindings();
  _bindingsReady = true;
}
