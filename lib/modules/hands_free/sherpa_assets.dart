import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Resolved on-disk paths for sherpa_onnx models used by the hands-free loop.
class SherpaAssetPaths {
  const SherpaAssetPaths({required this.vadSileroVad});

  final String vadSileroVad;
}

/// Thrown when [SherpaAssets.resolve] cannot locate the VAD model bundle.
class SherpaModelMissingException implements Exception {
  SherpaModelMissingException({required this.searchedPaths});

  final List<String> searchedPaths;

  @override
  String toString() =>
      'SherpaModelMissingException: VAD model not found. '
      'Searched: ${searchedPaths.join(", ")}';
}

/// Locate (and on first run, stage) the sherpa_onnx Silero VAD file.
class SherpaAssets {
  SherpaAssets._();

  static const String _vadName = 'silero_vad.onnx';

  static Future<SherpaAssetPaths> resolve() async {
    final searched = <String>[];

    // 1. App-support / sherpa/vad
    try {
      final appDir = await getApplicationSupportDirectory();
      final hit = await _tryDir('${appDir.path}/sherpa', searched);
      if (hit != null) return hit;
    } catch (_) {
      // platform-specific failure — fall through
    }

    // 2. External files / sherpa/vad (Android adb push target)
    if (Platform.isAndroid) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          final hit = await _tryDir('${ext.path}/sherpa', searched);
          if (hit != null) return hit;
        }
      } catch (_) {
        // best-effort
      }
    }

    // 3. Flutter asset bundle
    final staged = await _tryStageFromAssets(searched);
    if (staged != null) return staged;

    throw SherpaModelMissingException(searchedPaths: searched);
  }

  static Future<SherpaAssetPaths?> _tryDir(
    String baseDir,
    List<String> searched,
  ) async {
    final vadFile = File('$baseDir/vad/$_vadName');
    searched.add(vadFile.path);

    if (!await vadFile.exists() || await vadFile.length() == 0) return null;

    return SherpaAssetPaths(vadSileroVad: vadFile.path);
  }

  static Future<SherpaAssetPaths?> _tryStageFromAssets(
    List<String> searched,
  ) async {
    final appDir = await getApplicationSupportDirectory();
    final stagedVadDir = Directory('${appDir.path}/sherpa/vad');
    const vadAsset = 'assets/sherpa/vad/$_vadName';
    searched.add('asset:$vadAsset');

    try {
      await stagedVadDir.create(recursive: true);
      await _stageAsset(vadAsset, '${stagedVadDir.path}/$_vadName');
    } catch (_) {
      return null;
    }

    return SherpaAssetPaths(
      vadSileroVad: '${stagedVadDir.path}/$_vadName',
    );
  }

  static Future<void> _stageAsset(String assetPath, String destPath) async {
    final dest = File(destPath);
    final data = await rootBundle.load(assetPath);
    if (await dest.exists() && await dest.length() == data.lengthInBytes) {
      return;
    }
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    await dest.writeAsBytes(bytes, flush: true);
  }
}
