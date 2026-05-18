import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

/// Resolves on-disk locations for streaming TXT logs and exported PDFs.
class SessionLogPaths {
  SessionLogPaths._();

  /// App-scoped base for on-device logs (no `READ/WRITE_EXTERNAL_STORAGE`
  /// on modern Android — avoids scoped-storage permission failures).
  static Future<Directory> _appFilesBase() async {
    if (Platform.isIOS) {
      return getApplicationDocumentsDirectory();
    }
    final ext = await getExternalStorageDirectory();
    if (ext == null) {
      throw StateError('External storage directory unavailable.');
    }
    return ext;
  }

  /// App-specific directory — streaming `.txt` during session.
  static Future<Directory> txtDirectory() async {
    final base = await _appFilesBase();
    final dir = Directory('${base.path}/session_logs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Finished PDFs beside other app files (`…/files/Basecamp` on Android).
  /// Not the public Downloads tree — no runtime storage permission required.
  static Future<Directory> pdfExportDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final base = await _appFilesBase();
      final dir = Directory('${base.path}/Basecamp');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        final dir = Directory('${downloads.path}/Basecamp');
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir;
      }
    } catch (e) {
      debugPrint('SessionLogPaths: getDownloadsDirectory failed: $e');
    }
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/Basecamp');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Human-readable path shown in UI (may differ slightly by OEM).
  static Future<String> pdfExportDisplayPath() async {
    final dir = await pdfExportDirectory();
    return dir.path;
  }

  static Future<List<File>> listExportedPdfs() async {
    final dir = await pdfExportDirectory();
    if (!await dir.exists()) return const [];
    final entities = await dir.list().toList();
    final files = entities
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.pdf'))
        .toList();
    files.sort(
      (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
    );
    return files;
  }

  /// Finished sessions still on disk as `.txt` (e.g. PDF export failed earlier
  /// or the app was killed before conversion). Names must match `session_*.txt`.
  static Future<List<File>> listPendingTxtLogs() async {
    final dir = await txtDirectory();
    if (!await dir.exists()) return const [];
    final entities = await dir.list().toList();
    final files = entities
        .whereType<File>()
        .where((f) {
          final name = f.uri.pathSegments.last.toLowerCase();
          return name.endsWith('.txt') && name.startsWith('session_');
        })
        .toList();
    files.sort(
      (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
    );
    return files;
  }
}
