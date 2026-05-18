/// Infers spoken language from Whisper transcript text (after `auto`
/// transcription). Whisper.cpp detects language internally; the plugin
/// does not expose it in Dart, so we infer from script statistics.
class LanguageDetector {
  LanguageDetector._();

  static const String urdu = 'ur';
  static const String english = 'en';
  static const String unknown = 'unknown';

  /// Returns ISO-ish code (`ur`, `en`, or `unknown`) and confidence
  /// in `[0, 1]`.
  static ({String language, double confidence}) detectFromText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return (language: unknown, confidence: 0.0);
    }

    var urduChars = 0;
    var latinChars = 0;

    for (final rune in trimmed.runes) {
      if (_isUrduScript(rune)) {
        urduChars++;
      } else if (_isLatinLetter(rune)) {
        latinChars++;
      }
    }

    final letterTotal = urduChars + latinChars;
    if (letterTotal == 0) {
      return (language: english, confidence: 0.5);
    }

    if (urduChars > latinChars && urduChars >= letterTotal * 0.25) {
      return (
        language: urdu,
        confidence: (urduChars / letterTotal).clamp(0.0, 1.0),
      );
    }

    if (latinChars >= urduChars) {
      return (
        language: english,
        confidence: (latinChars / letterTotal).clamp(0.0, 1.0),
      );
    }

    return (language: unknown, confidence: 0.4);
  }

  /// Maps Whisper / detector codes to Gemma + TTS language keys.
  static String normalizeForPipeline(String? code) {
    final c = (code ?? '').trim().toLowerCase();
    if (c == urdu || c.startsWith('ur')) return urdu;
    if (c == english || c.startsWith('en')) return english;
    return unknown;
  }

  static bool _isUrduScript(int rune) =>
      (rune >= 0x0600 && rune <= 0x06FF) ||
      (rune >= 0x0750 && rune <= 0x077F) ||
      (rune >= 0xFB50 && rune <= 0xFDFF) ||
      (rune >= 0xFE70 && rune <= 0xFEFF);

  static bool _isLatinLetter(int rune) =>
      (rune >= 0x41 && rune <= 0x5A) ||
      (rune >= 0x61 && rune <= 0x7A);
}
