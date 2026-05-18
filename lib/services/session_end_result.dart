/// Outcome of ending a session (TXT flush + optional PDF export).
class SessionEndResult {
  const SessionEndResult({
    required this.pdfSaved,
    required this.userMessage,
    this.pdfPath,
    this.txtPath,
  });

  /// True when a PDF was written under app storage (`Basecamp` folder).
  final bool pdfSaved;

  /// Path to the exported PDF, if [pdfSaved].
  final String? pdfPath;

  /// Path to the on-disk `.txt` log when PDF export failed or was skipped.
  final String? txtPath;

  /// Snackbar / banner copy for the responder.
  final String userMessage;

  /// Backward-compatible path for callers expecting a single file path.
  String? get primaryPath => pdfPath ?? txtPath;
}
