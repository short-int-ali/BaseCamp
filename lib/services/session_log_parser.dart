/// Parsed representation of a flushed session `.txt` file.
class ParsedSessionLog {
  ParsedSessionLog({
    required this.startedAtIso,
    required this.rawLines,
    required this.events,
    required this.summary,
    this.languages = const [],
  });

  final String? startedAtIso;
  final List<String> rawLines;
  final List<SessionLogEvent> events;
  final SessionLogSummary summary;
  final List<String> languages;
}

class SessionLogEvent {
  const SessionLogEvent({
    this.time,
    required this.tag,
    this.value,
  });

  final String? time;
  final String tag;
  final String? value;
}

class SessionLogSummary {
  const SessionLogSummary({
    this.duration,
    this.turns,
    this.finalTriage,
    this.toolsUsed,
    this.endedAtIso,
  });

  final String? duration;
  final String? turns;
  final String? finalTriage;
  final String? toolsUsed;
  final String? endedAtIso;
}

/// Line-oriented parser for on-disk session logs.
class SessionLogParser {
  static ParsedSessionLog parse(String content) {
    final lines = content.split('\n');
    String? startedAtIso;
    final events = <SessionLogEvent>[];
    final languages = <String>{};
    final summary = <String, String>{};

    var inSummary = false;
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.isEmpty) continue;

      if (line.startsWith('Started: ')) {
        startedAtIso = line.substring('Started: '.length).trim();
        continue;
      }

      if (line == 'Session summary') {
        inSummary = true;
        continue;
      }

      if (inSummary) {
        final idx = line.indexOf(': ');
        if (idx > 0) {
          summary[line.substring(0, idx)] = line.substring(idx + 2);
        }
        continue;
      }

      final event = _parseEventLine(line);
      if (event != null) {
        events.add(event);
        if (event.tag == 'USER_LANGUAGE_DETECTED' &&
            event.value != null &&
            event.value!.isNotEmpty) {
          languages.add(event.value!);
        }
      }
    }

    return ParsedSessionLog(
      startedAtIso: startedAtIso,
      rawLines: lines,
      events: events,
      languages: languages.toList(),
      summary: SessionLogSummary(
        duration: summary['Duration'],
        turns: summary['Turns'],
        finalTriage: summary['Final triage'],
        toolsUsed: summary['Tools used'],
        endedAtIso: summary['Ended'],
      ),
    );
  }

  static SessionLogEvent? _parseEventLine(String line) {
    if (!line.startsWith('[')) return null;
    final close = line.indexOf(']');
    if (close < 2) return null;
    final time = line.substring(1, close);
    final body = line.substring(close + 1).trim();
    if (body.isEmpty) return null;
    final colon = body.indexOf(': ');
    if (colon > 0) {
      return SessionLogEvent(
        time: time,
        tag: body.substring(0, colon),
        value: body.substring(colon + 2),
      );
    }
    return SessionLogEvent(time: time, tag: body);
  }
}
