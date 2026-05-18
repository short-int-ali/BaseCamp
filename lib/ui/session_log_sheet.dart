import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../services/session_log_pdf_exporter.dart';
import '../theme/emergency_theme.dart';
import 'components/base_camp_components.dart';
import 'session_logs_screen.dart';

Future<void> _convertTxtToPdfAndUse(
  BuildContext context,
  String txtPath,
  Future<void> Function(String pdfPath) usePdf,
) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(
        child: CircularProgressIndicator(
          color: EmergencyPalette.emergencyRed,
        ),
      ),
    ),
  );
  try {
    final result =
        await SessionLogPdfExporter.convertAndArchive(txtPath: txtPath);
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (result.pdfSaved && result.pdfPath != null) {
      await usePdf(result.pdfPath!);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.userMessage)),
      );
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create PDF: $e')),
      );
    }
  }
}

/// Quick actions after a session ends (PDF or fallback TXT path).
class SessionLogSheet extends StatelessWidget {
  const SessionLogSheet({
    super.key,
    required this.logPath,
    this.isPdf = true,
  });

  final String logPath;
  final bool isPdf;

  static Future<void> show(
    BuildContext context,
    String logPath, {
    bool isPdf = true,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: EmergencyPalette.surfaceElevated,
      builder: (_) => SessionLogSheet(logPath: logPath, isPdf: isPdf),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BaseCampSheetHeader(
            title: isPdf ? 'Session PDF' : 'Export session as PDF',
            icon: isPdf
                ? Icons.picture_as_pdf_rounded
                : Icons.picture_as_pdf_outlined,
            onClose: () => Navigator.of(context).pop(),
          ),
          const SizedBox(height: 12),
          Text(
            logPath,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () async {
              if (isPdf) {
                await OpenFilex.open(logPath, type: 'application/pdf');
                if (context.mounted) Navigator.of(context).pop();
                return;
              }
              await _convertTxtToPdfAndUse(context, logPath, (pdfPath) async {
                await OpenFilex.open(pdfPath, type: 'application/pdf');
                if (context.mounted) Navigator.of(context).pop();
              });
            },
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(isPdf ? 'Open PDF' : 'Create PDF & open'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              if (isPdf) {
                await Share.shareXFiles(
                  [
                    XFile(
                      logPath,
                      mimeType: 'application/pdf',
                    ),
                  ],
                  subject: 'Base Camp session log',
                );
                return;
              }
              await _convertTxtToPdfAndUse(context, logPath, (pdfPath) async {
                await Share.shareXFiles(
                  [
                    XFile(
                      pdfPath,
                      mimeType: 'application/pdf',
                    ),
                  ],
                  subject: 'Base Camp session log',
                );
              });
            },
            icon: const Icon(Icons.share_rounded),
            label: const Text('Share PDF'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SessionLogsScreen(),
                ),
              );
            },
            child: const Text('View all session logs'),
          ),
        ],
      ),
    );
  }
}

/// Post-session actions: open PDF and share.
class SessionEndedBanner extends StatelessWidget {
  const SessionEndedBanner({
    super.key,
    required this.logPath,
    required this.onDismiss,
    this.isPdf = true,
  });

  final String logPath;
  final VoidCallback onDismiss;
  final bool isPdf;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: BaseCampSurfaceCard(
        accentColor: EmergencyPalette.triageGreen.withValues(alpha: 0.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: EmergencyPalette.triageGreen,
                ),
                const SizedBox(width: 8),
                Text(
                  isPdf ? 'Session saved as PDF' : 'Session log — export PDF',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: EmergencyPalette.triageGreen,
                      ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: onDismiss,
                  tooltip: 'Dismiss',
                  style: IconButton.styleFrom(
                    minimumSize: const Size(32, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => SessionLogSheet.show(
                      context,
                      logPath,
                      isPdf: isPdf,
                    ),
                    child: Text(isPdf ? 'Open PDF' : 'Export PDF…'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      if (isPdf) {
                        await Share.shareXFiles(
                          [
                            XFile(
                              logPath,
                              mimeType: 'application/pdf',
                            ),
                          ],
                          subject: 'Base Camp session log',
                        );
                        return;
                      }
                      await _convertTxtToPdfAndUse(context, logPath,
                          (pdfPath) async {
                        await Share.shareXFiles(
                          [
                            XFile(
                              pdfPath,
                              mimeType: 'application/pdf',
                            ),
                          ],
                          subject: 'Base Camp session log',
                        );
                      });
                    },
                    child: const Text('Share PDF'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
