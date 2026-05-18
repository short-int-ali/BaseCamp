import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:path_provider/path_provider.dart';

/// Default on-disk location the app expects the LiteRT-LM bundle at,
/// relative to the Flutter asset bundle.
///
/// Base Camp targets the Gemma 4 **E2B** int4 multimodal bundle. E2B
/// (~2B effective parameters) is the smaller of the two ship-ready
/// Gemma 4 multimodal variants and fits comfortably inside the LMK
/// cgroup budget on 6–8 GB Android devices alongside the camera
/// preview, audio recorder, and system TTS engine. The earlier E4B
/// scaffold is preserved in git history; do **not** mix and match —
/// LiteRT-LM bundles are variant-specific.
const String kDefaultModelAssetPath =
    'assets/models/gemma4_e2b_int4.litertlm';

/// Hard ceiling on total tokens (prompt + generated) the engine
/// reserves KV cache for. Gemma 4 E2B ships with the same 8k-context
/// default as E4B; left unbounded the cache would still sink hundreds
/// of MB on-device, and our prompts top out around ~350 tokens with
/// intentionally short responses.
///
/// 2048 is chosen (rather than a tighter 1024) to keep comfortable
/// headroom for the multimodal prefill budget: a 512-px image adds
/// ~225 vision tokens, a 30 s audio clip adds up to ~600 audio
/// tokens, and the system prompt runs ~200. Below ~1500 the
/// compiled model executor starts returning INTERNAL errors on
/// multimodal graphs.
const int kMaxNumTokens = 2048;

/// Thrown when [ModelEngine.create] cannot locate the model bundle.
/// The UI catches this to render the first-boot gate.
///
/// [searchedPaths] enumerates every on-disk location the loader tried,
/// in priority order, so the UI can tell the user exactly where to
/// drop or `adb push` the file.
class ModelMissingException implements Exception {
  ModelMissingException({
    required this.expectedPath,
    required this.searchedPaths,
  });

  /// Primary path (the asset-bundle-relative name). Kept for backward
  /// compatibility with existing callers.
  final String expectedPath;

  /// Every location checked, in the order they were tried.
  final List<String> searchedPaths;

  @override
  String toString() =>
      'ModelMissingException: LiteRT-LM bundle not found. '
      'Searched: ${searchedPaths.join(", ")}';
}

/// Single-ownership wrapper around [LiteLmEngine]. Both the vision
/// and audio modules share this instance so the Gemma 4 E2B int4
/// weights (~1.5–2 GB resident) are loaded exactly once.
///
/// **Session rule (LiteRT-LM JNI):** the native runtime allows **at
/// most one** [LiteLmConversation] per [LiteLmEngine] at a time.
/// [AudioGateway] holds a long-lived conversation for multi-turn ASK.
/// Multimodal photo turns use the same conversation via
/// [LiteLmConversation.sendMultimodalMessageStream].
///
/// Typical usage:
///
/// ```dart
/// final modelEngine = ModelEngine();
/// await modelEngine.create();
/// final audio = AudioGateway(engine: modelEngine, kb: kb);
/// ```
class ModelEngine {
  ModelEngine();

  LiteLmEngine? _engine;
  bool _initialized = false;
  String _modelAssetPath = kDefaultModelAssetPath;

  /// Optional hook invoked from [prepareForVisionInference] before
  /// vision opens a conversation. Usually bound to
  /// [AudioGateway.suspendForExternalInference].
  Future<void> Function()? beforeVisionSession;

  /// The underlying engine. Null until [create] completes.
  LiteLmEngine? get engine => _engine;

  bool get isInitialized => _initialized;

  /// Await this immediately before creating a vision conversation.
  /// Releases the ASK tab's session when [beforeVisionSession] is set.
  Future<void> prepareForVisionInference() async {
    final hook = beforeVisionSession;
    if (hook != null) await hook();
  }

  /// Resolve the model on disk and bring up the [LiteLmEngine].
  ///
  /// Throws [ModelMissingException] if no model bundle can be found.
  /// Safe to call more than once — later calls are a no-op.
  /// Rebuild the native engine after an OpenCL / GPU fault. Clears a
  /// poisoned GPU context without restarting the app.
  Future<void> recreateAfterNativeFault() async {
    // #region agent log
    print('[DBG-b37fdb] H7 recreate: initialized=$_initialized');
    // #endregion
    if (!_initialized) return;
    debugPrint('ModelEngine: recreating after native fault');
    await dispose();
    await create(modelAssetPath: _modelAssetPath);
    // #region agent log
    print('[DBG-b37fdb] H7 recreate DONE: engine=${_engine != null}, initialized=$_initialized');
    // #endregion
  }

  Future<void> create({
    String modelAssetPath = kDefaultModelAssetPath,
  }) async {
    if (_initialized) return;

    _modelAssetPath = modelAssetPath;
    final modelPath = await _ensureModelOnDisk(modelAssetPath);
    final modelFile = File(modelPath);
    final modelBytes = await modelFile.length();
    final expectedName = modelAssetPath.split('/').last;
    final loadedName = modelPath.split(Platform.pathSeparator).last;
    if (loadedName != expectedName) {
      debugPrint(
        'ModelEngine: WARNING loaded "$loadedName" but expected "$expectedName"',
      );
    }
    final backend = _pickBackend();
    debugPrint(
      'ModelEngine: LiteRT-LM path=$modelPath '
      'size=$modelBytes backend=$backend',
    );

    // CPU for everything except the text decoder: the .litertlm
    // bundle for Gemma 4 E2B is compiled against the GPU dispatcher
    // for the text decoder, but the vision and audio towers are both
    // small and stable on CPU. Keeping the towers on CPU avoids
    // double-booking GPU memory with the text decoder's KV cache on
    // mobile GPUs.
    //
    // `visionBackend` and `audioBackend` must be non-null for
    // multimodal input — without them the native JNI layer null-
    // derefs inside nativeSendMessage. Our plugin fork wires both
    // through to the upstream Kotlin EngineConfig; upstream 0.3.0
    // drops them on the floor.
    //
    // `maxNumTokens` caps the KV cache allocation; see constant docs.
    final built = await LiteLmEngine.create(
      LiteLmEngineConfig(
        modelPath: modelPath,
        backend: backend,
        visionBackend: LiteLmBackend.cpu,
        audioBackend: LiteLmBackend.cpu,
        maxNumTokens: kMaxNumTokens,
      ),
    );
    _engine = built;
    _initialized = true;
  }

  /// Release the engine and all native resources.
  Future<void> dispose() async {
    // #region agent log
    print('[DBG-b37fdb] H8 ModelEngine.dispose CALLED initialized=$_initialized engine=${_engine != null}');
    // #endregion
    beforeVisionSession = null;
    await _engine?.dispose();
    _engine = null;
    _initialized = false;
  }

  // ------------------------------------------------------------------
  // Backend selection
  // ------------------------------------------------------------------

  LiteLmBackend _pickBackend() {
    // iOS only supports CPU today (Metal accelerator isn't shipped
    // upstream).
    //
    // On Android we use GPU for the text decoder. Empirically the
    // .litertlm bundles produced for Gemma 4 E2B (and E4B) are
    // compiled/tuned against the GPU dispatcher, and attempting to
    // run them on the CPU backend surfaces an INTERNAL error
    // ("Failed to invoke the compiled model") from
    // llm_litert_compiled_model_executor.cc at the first sendMessage.
    // Even on budget MediaTek GPUs the OpenCL path works for the
    // decoder; we mitigate peak memory elsewhere (camera dispose
    // during inference, 512 px vision input, bounded KV cache, audio
    // tower on CPU).
    if (Platform.isIOS) return LiteLmBackend.cpu;
    return LiteLmBackend.gpu;
  }

  // ------------------------------------------------------------------
  // Model asset management
  // ------------------------------------------------------------------

  /// Resolve the on-disk absolute path the LiteRT-LM engine expects.
  ///
  /// Strategy, in priority order:
  ///   1. If a copy already exists in app-support, use it.
  ///   2. On Android, if a copy exists in the app-specific external
  ///      files dir (the `adb push` target), use it **in place** —
  ///      no copy, because the bundle is multi-gigabyte.
  ///   3. Else, try to read the model out of the Flutter asset bundle
  ///      and copy it into app-support.
  ///   4. If none of those work, throw [ModelMissingException] with
  ///      every path we tried, so the UI gate can show the user
  ///      exactly where to drop / push the file.
  Future<String> _ensureModelOnDisk(String assetPath) async {
    final filename = assetPath.split('/').last;
    final searched = <String>[];

    // 1. App-support (the canonical staged location).
    final appDir = await getApplicationSupportDirectory();
    final staged = File('${appDir.path}/$filename');
    searched.add(staged.path);
    if (await staged.exists() && await staged.length() > 0) {
      return staged.path;
    }

    // 2. Android-only: app-specific external files dir. This is the
    //    recommended home for models pushed via
    //    `adb push <file> /sdcard/Android/data/<pkg>/files/`.
    //    It requires no runtime permissions on API 19+ and survives
    //    app upgrades. iOS has no equivalent and throws here, which
    //    we swallow.
    if (Platform.isAndroid) {
      try {
        final externalDir = await getExternalStorageDirectory();
        if (externalDir != null) {
          final pushed = File('${externalDir.path}/$filename');
          searched.add(pushed.path);
          if (await pushed.exists() && await pushed.length() > 0) {
            return pushed.path;
          }
        }
      } catch (_) {
        // Non-fatal: fall through to asset bundle.
      }
    }

    // 3. Flutter asset bundle — only useful for small/test models.
    searched.add('asset:$assetPath');
    try {
      final bytes = await rootBundle.load(assetPath);
      await staged.writeAsBytes(
        bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        ),
        flush: true,
      );
      return staged.path;
    } catch (_) {
      throw ModelMissingException(
        expectedPath: assetPath,
        searchedPaths: searched,
      );
    }
  }
}
