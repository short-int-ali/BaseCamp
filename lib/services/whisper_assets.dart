import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

/// Thrown when the GGML Whisper model cannot be located on disk.
class WhisperModelMissingException implements Exception {
  WhisperModelMissingException({required this.searchedPaths});

  final List<String> searchedPaths;

  @override
  String toString() =>
      'WhisperModelMissingException: ggml-tiny.bin not found. '
      'Searched: ${searchedPaths.join(", ")}';
}

/// Resolve and stage `assets/whisper/ggml-tiny.bin` for [WhisperTranscriber].
class WhisperAssets {
  WhisperAssets._();

  static const String _modelFileName = 'ggml-tiny.bin';
  static const String _assetPath = 'assets/whisper/$_modelFileName';

  /// Canonical on-disk path whisper_ggml expects for [WhisperModel.tiny].
  static Future<String> resolveModelPath() async {
    final searched = <String>[];
    final modelDir = await WhisperController.getModelDir();
    final canonical = '$modelDir/$_modelFileName';
    searched.add(canonical);

    final file = File(canonical);
    if (await file.exists() && await file.length() > 0) {
      return canonical;
    }

    if (Platform.isAndroid) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          final extPath = '${ext.path}/whisper/$_modelFileName';
          searched.add(extPath);
          final extFile = File(extPath);
          if (await extFile.exists() && await extFile.length() > 0) {
            await file.parent.create(recursive: true);
            await extFile.copy(canonical);
            return canonical;
          }
        }
      } catch (_) {
        // best-effort
      }
    }

    searched.add('asset:$_assetPath');
    try {
      final data = await rootBundle.load(_assetPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return canonical;
    } catch (_) {
      throw WhisperModelMissingException(searchedPaths: searched);
    }
  }
}
