import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../constants/disclaimers.dart';
import 'app_permissions.dart';
import 'session_end_result.dart';
import 'session_log_parser.dart';
import 'session_log_paths.dart';

/// One-shot TXT → PDF conversion at session end (not during conversation).
class SessionLogPdfExporter {
  SessionLogPdfExporter._();

  /// Converts a finished—or orphaned—`.txt` session log to PDF and removes
  /// the text file on success. When [startedAt] / [turnCount] / metadata are
  /// omitted (e.g. importing an old log), values are derived from the file.
  static Future<SessionEndResult> convertAndArchive({
    required String txtPath,
    DateTime? startedAt,
    int? turnCount,
    String? finalTriage,
    String? toolsUsed,
  }) async {
    final txtFile = File(txtPath);
    if (!await txtFile.exists()) {
      return const SessionEndResult(
        pdfSaved: false,
        userMessage: 'Session log file not found.',
      );
    }

    if (!await requestStorageForSessionLogs()) {
      return SessionEndResult(
        pdfSaved: false,
        txtPath: txtPath,
        userMessage: 'Cannot save logs without storage permission.',
      );
    }

    await _appendTxtLine(txtFile, 'PDF_CONVERSION_START');

    try {
      final content = await txtFile.readAsString();
      final parsed = SessionLogParser.parse(content);
      final integrityHash = sha256.convert(utf8.encode(content)).toString();

      final derivedStarted = startedAt ??
          DateTime.tryParse(parsed.startedAtIso ?? '') ??
          await txtFile.lastModified();
      final derivedTurns = turnCount ??
          int.tryParse(parsed.summary.turns ?? '') ??
          parsed.events.where((e) => e.tag == 'TURN_START').length;
      final derivedTriage = finalTriage ?? parsed.summary.finalTriage ?? 'none';
      final derivedTools =
          toolsUsed ?? _deriveToolsUsed(parsed);

      final exportDir = await SessionLogPaths.pdfExportDirectory();
      final stamp = _stampFromTxtPath(txtPath) ?? _fileStamp(DateTime.now());
      final pdfName = 'session_$stamp.pdf';
      final pdfFile = File('${exportDir.path}/$pdfName');

      final doc = _buildDocument(
        parsed: parsed,
        integrityHash: integrityHash,
        startedAt: derivedStarted,
        turnCount: derivedTurns,
        finalTriage: derivedTriage,
        toolsUsed: derivedTools,
        pdfFileName: pdfName,
        exportPath: exportDir.path,
      );

      final bytes = await doc.save();
      await pdfFile.writeAsBytes(bytes, flush: true);

      await _appendTxtLine(
        txtFile,
        'PDF_CONVERSION_COMPLETE: $pdfName',
      );
      await _appendTxtLine(txtFile, 'TXT_FILE_DELETED');
      await txtFile.delete();

      return SessionEndResult(
        pdfSaved: true,
        pdfPath: pdfFile.path,
        userMessage: 'Session saved as PDF',
      );
    } on FileSystemException catch (e) {
      debugPrint('SessionLogPdfExporter: disk error: $e');
      await _appendTxtLine(txtFile, 'PDF_CONVERSION_ERROR: $e');
      return SessionEndResult(
        pdfSaved: false,
        txtPath: txtPath,
        userMessage: 'Not enough storage or cannot write PDF — text log kept.',
      );
    } catch (e, st) {
      debugPrint('SessionLogPdfExporter failed: $e\n$st');
      await _appendTxtLine(txtFile, 'PDF_CONVERSION_ERROR: $e');
      return SessionEndResult(
        pdfSaved: false,
        txtPath: txtPath,
        userMessage: 'PDF conversion failed — text log kept.',
      );
    }
  }

  /// Converts every `session_*.txt` in app storage except [excludePath] (the
  /// live session file, if any). Returns how many PDFs were written.
  static Future<int> migratePendingTxtLogs({String? excludePath}) async {
    if (!await requestStorageForSessionLogs()) return 0;
    final txts = await SessionLogPaths.listPendingTxtLogs();
    var saved = 0;
    for (final f in txts) {
      if (excludePath != null && f.path == excludePath) continue;
      final r = await convertAndArchive(txtPath: f.path);
      if (r.pdfSaved) saved++;
    }
    return saved;
  }

  static String _deriveToolsUsed(ParsedSessionLog parsed) {
    final s = parsed.summary.toolsUsed;
    if (s != null && s.isNotEmpty) return s;
    final names = <String>{};
    for (final e in parsed.events) {
      if (e.tag == 'AGENTIC_CALL' &&
          e.value != null &&
          e.value!.isNotEmpty) {
        names.add(e.value!);
      }
    }
    return names.isEmpty ? 'none' : names.join(', ');
  }

  static pw.Document _buildDocument({
    required ParsedSessionLog parsed,
    required String integrityHash,
    required DateTime startedAt,
    required int turnCount,
    required String finalTriage,
    required String toolsUsed,
    required String pdfFileName,
    required String exportPath,
  }) {
    final doc = pw.Document(
      title: 'Base Camp Session Log',
      author: 'Base Camp',
      creator: 'Base Camp (offline)',
      subject: 'First-aid session record',
    );

    final transcript = _transcriptLines(parsed.events);
    final agentic = _agenticLines(parsed.events);
    final languages = parsed.languages.isEmpty
        ? 'not recorded'
        : parsed.languages.join(', ');

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        header: (ctx) => pw.Text(
          'BASE CAMP SESSION LOG',
          style: pw.TextStyle(
            fontSize: 16,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        footer: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Divider(),
            pw.Text(
              kNonDiagnosticDisclaimer,
              style: const pw.TextStyle(fontSize: 8),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              'Integrity (SHA-256 of source log): $integrityHash',
              style: const pw.TextStyle(fontSize: 7),
            ),
            pw.Text(
              'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: const pw.TextStyle(fontSize: 7),
            ),
          ],
        ),
        build: (ctx) => [
          pw.Header(
            level: 1,
            child: pw.Text(
              'Session metadata',
              style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          _metaRow('Started', parsed.startedAtIso ?? startedAt.toIso8601String()),
          _metaRow('Ended', parsed.summary.endedAtIso ?? '—'),
          _metaRow(
            'Duration',
            parsed.summary.duration ?? '—',
          ),
          _metaRow('Turns', parsed.summary.turns ?? turnCount.toString()),
          _metaRow('Languages detected', languages),
          _metaRow('Final triage', parsed.summary.finalTriage ?? finalTriage),
          _metaRow('Tools used', parsed.summary.toolsUsed ?? toolsUsed),
          _metaRow('PDF file', pdfFileName),
          _metaRow('Export folder', exportPath),
          pw.SizedBox(height: 16),
          pw.Header(
            level: 1,
            child: pw.Text(
              'Conversation transcript',
              style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          if (transcript.isEmpty)
            pw.Text('No transcript events recorded.')
          else
            ...transcript.map(
              (line) => pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 6),
                child: pw.Text(line, style: const pw.TextStyle(fontSize: 10)),
              ),
            ),
          pw.SizedBox(height: 16),
          pw.Header(
            level: 1,
            child: pw.Text(
              'Agentic actions',
              style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          if (agentic.isEmpty)
            pw.Text('No agentic tools invoked.')
          else
            ...agentic.map(
              (line) => pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 4),
                child: pw.Text(line, style: const pw.TextStyle(fontSize: 10)),
              ),
            ),
          pw.SizedBox(height: 16),
          pw.Header(
            level: 1,
            child: pw.Text(
              'Final assessment',
              style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          ..._assessmentLines(parsed.events).map(
            (line) => pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 6),
              child: pw.Text(line, style: const pw.TextStyle(fontSize: 10)),
            ),
          ),
          pw.SizedBox(height: 12),
          pw.Text(
            'Archival: PDF_CONVERSION_START → PDF_CONVERSION_COMPLETE → '
            'TXT_FILE_DELETED (source .txt removed after successful export).',
            style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic),
          ),
        ],
      ),
    );

    return doc;
  }

  static pw.Widget _metaRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.RichText(
        text: pw.TextSpan(
          children: [
            pw.TextSpan(
              text: '$label: ',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10),
            ),
            pw.TextSpan(text: value, style: const pw.TextStyle(fontSize: 10)),
          ],
        ),
      ),
    );
  }

  static List<String> _transcriptLines(List<SessionLogEvent> events) {
    final out = <String>[];
    for (final e in events) {
      switch (e.tag) {
        case 'TURN_START':
        case 'TURN_END':
        case 'USER_AUDIO_TRANSCRIBED':
        case 'GEMMA_RESPONSE':
        case 'USER_LANGUAGE_DETECTED':
        case 'TTS_FALLBACK':
        case 'STREAMING_TTS_START':
        case 'SENTENCE_QUEUED_TO_TTS':
        case 'STREAMING_TTS_COMPLETE':
          out.add(_formatEvent(e));
        default:
          break;
      }
    }
    return out;
  }

  static List<String> _agenticLines(List<SessionLogEvent> events) {
    final out = <String>[];
    for (final e in events) {
      switch (e.tag) {
        case 'AGENTIC_CALL':
        case 'TOOL_EXECUTED':
        case 'CAMERA_MODAL_REQUESTED':
        case 'CAMERA_IMAGE_CAPTURED':
        case 'CAMERA_IMAGE_INJECTED':
        case 'CAMERA_CANCELLED':
        case 'USER_RESPONSE':
          out.add(_formatEvent(e));
        default:
          break;
      }
    }
    return out;
  }

  static List<String> _assessmentLines(List<SessionLogEvent> events) {
    final out = <String>[];
    for (final e in events) {
      if (e.tag == 'TRIAGE' || e.tag == 'GEMMA_RESPONSE') {
        out.add(_formatEvent(e));
      }
    }
    if (out.isEmpty) {
      out.add('No triage or model assessment lines recorded.');
    }
    return out;
  }

  static String _formatEvent(SessionLogEvent e) {
    final ts = e.time != null ? '[${e.time}] ' : '';
    if (e.value == null || e.value!.isEmpty) {
      return '$ts${e.tag}';
    }
    return '$ts${e.tag}: ${e.value}';
  }

  static Future<void> _appendTxtLine(File file, String body) async {
    final ts = _lineStamp(DateTime.now());
    await file.writeAsString('[$ts] $body\n', mode: FileMode.append, flush: true);
  }

  static String? _stampFromTxtPath(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final m = RegExp(r'session_(\d{8}_\d{6})\.txt').firstMatch(name);
    return m?.group(1);
  }

  static String _fileStamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y$mo${d}_$h$mi$s';
  }

  static String _lineStamp(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$mi:$s';
  }
}
