import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../services/session_log.dart';
import '../services/session_log_paths.dart';
import '../services/session_log_pdf_exporter.dart';
import '../theme/emergency_theme.dart';
import 'components/base_camp_components.dart';

/// Lists exported session PDFs from app storage and opens them
/// with the system PDF viewer.
class SessionLogsScreen extends StatefulWidget {
  const SessionLogsScreen({super.key});

  @override
  State<SessionLogsScreen> createState() => _SessionLogsScreenState();
}

class _SessionLogsScreenState extends State<SessionLogsScreen> {
  Future<List<File>>? _loadFuture;
  String? _folderPath;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _loadFuture = _load();
    });
  }

  Future<List<File>> _load() async {
    _folderPath = await SessionLogPaths.pdfExportDisplayPath();
    await SessionLogPdfExporter.migratePendingTxtLogs(
      excludePath: SessionLog.instance?.file.path,
    );
    return SessionLogPaths.listExportedPdfs();
  }

  Future<void> _openPdf(File file) async {
    final result = await OpenFilex.open(
      file.path,
      type: 'application/pdf',
    );
    if (!mounted) return;
    if (result.type != ResultType.done) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.message.isNotEmpty
                ? result.message
                : 'Could not open PDF.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EmergencyPalette.background,
      appBar: AppBar(
        title: const Text('Session logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const BaseCampHeaderAccent(),
          if (_folderPath != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Folder: $_folderPath',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: EmergencyPalette.onSurfaceMuted,
                    ),
              ),
            ),
          Expanded(
            child: FutureBuilder<List<File>>(
              future: _loadFuture,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: EmergencyPalette.emergencyRed,
                    ),
                  );
                }
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Could not load logs:\n${snap.error}'),
                    ),
                  );
                }
                final files = snap.data ?? const [];
                if (files.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No session PDFs yet.\n\n'
                        'End an ASK session to save a PDF here, or pull down '
                        'to refresh — pending text logs are converted when '
                        'you open this screen.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: files.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final file = files[i];
                    final name = file.uri.pathSegments.last;
                    final modified = file.lastModifiedSync();
                    return BaseCampSurfaceCard(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.picture_as_pdf_rounded,
                          color: EmergencyPalette.emergencyRed,
                        ),
                        title: Text(name),
                        subtitle: Text(
                          '${modified.year}-${modified.month.toString().padLeft(2, '0')}-'
                          '${modified.day.toString().padLeft(2, '0')} '
                          '${modified.hour.toString().padLeft(2, '0')}:'
                          '${modified.minute.toString().padLeft(2, '0')}',
                        ),
                        onTap: () => _openPdf(file),
                        trailing: IconButton(
                          icon: const Icon(Icons.share_rounded),
                          onPressed: () => Share.shareXFiles(
                            [XFile(file.path, mimeType: 'application/pdf')],
                            subject: 'Base Camp session log',
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: BaseCampDisclaimerBanner(
              text:
                  'PDFs are saved in app storage (path above). Use Share from a '
                  'row to send a copy (e.g. to Downloads or email).',
            ),
          ),
        ],
      ),
    );
  }
}
