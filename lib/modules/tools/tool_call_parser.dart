import 'tool_call.dart';

/// Extracts and strips `<TOOL_CALL>` blocks from model text.
///
/// Gemma often emits a well-formed JSON payload without the closing
/// `</TOOL_CALL>` tag. The stream parser then splices the raw tag into
/// the transcript on [ToolCallStreamParser.flush] and never dispatches
/// the tool. This helper recovers those cases for display + execution.
class ToolCallExtractor {
  ToolCallExtractor._();

  static final RegExp _closedTag = RegExp(
    r'<TOOL_CALL>\s*([\s\S]*?)\s*</TOOL_CALL>',
    caseSensitive: false,
  );

  static const String _openTag = '<TOOL_CALL>';

  static List<ToolCall> extractFromText(String text) {
    if (text.isEmpty) return const <ToolCall>[];
    final seen = <String>{};
    final out = <ToolCall>[];

    void addPayload(String payload) {
      final trimmed = payload.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) return;
      final call = ToolCall.tryParse(trimmed);
      if (call != null) out.add(call);
    }

    for (final m in _closedTag.allMatches(text)) {
      final payload = m.group(1);
      if (payload != null) addPayload(payload);
    }

    final lower = text.toLowerCase();
    var searchFrom = 0;
    while (true) {
      final open = lower.indexOf(_openTag.toLowerCase(), searchFrom);
      if (open < 0) break;
      final afterOpen = open + _openTag.length;
      final close = lower.indexOf('</tool_call>', afterOpen);
      if (close < 0) {
        final json = _extractBalancedJson(text, afterOpen);
        if (json != null) addPayload(json);
      }
      searchFrom = afterOpen;
    }
    return out;
  }

  /// Finds the first `{...}` object after [fromIndex] using brace depth.
  static String? _extractBalancedJson(String text, int fromIndex) {
    final start = text.indexOf('{', fromIndex);
    if (start < 0) return null;
    var depth = 0;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          return text.substring(start, i + 1);
        }
      }
    }
    return null;
  }

  static String stripFromText(String text) {
    if (text.isEmpty) return text;
    var out = text.replaceAll(_closedTag, '');

    final lower = out.toLowerCase();
    final buf = StringBuffer();
    var i = 0;
    while (i < out.length) {
      final open = lower.indexOf(_openTag.toLowerCase(), i);
      if (open < 0) {
        buf.write(out.substring(i));
        break;
      }
      buf.write(out.substring(i, open));
      final afterOpen = open + _openTag.length;
      final close = lower.indexOf('</tool_call>', afterOpen);
      if (close >= 0) {
        i = close + '</TOOL_CALL>'.length;
        continue;
      }
      final json = _extractBalancedJson(out, afterOpen);
      if (json != null) {
        i = afterOpen + json.length;
      } else {
        i = afterOpen;
      }
    }
    out = buf.toString();
    out = out.replaceAll(
      RegExp(r'<TOOL_CALL>\s*', caseSensitive: false),
      '',
    );
    return out.replaceAll(RegExp(r'[ \t]{2,}'), ' ').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }
}

/// Result of feeding one streamed chunk through [ToolCallStreamParser].
class ToolParseChunk {
  const ToolParseChunk({required this.cleanedText, required this.calls});

  /// Tokens safe to render and (later) speak. The raw `<TOOL_CALL>` tag
  /// has been stripped and held back is also deferred (the parser
  /// keeps a small tail buffer so we never emit a partial open tag
  /// that the next chunk completes).
  final String cleanedText;

  /// Tool calls fully accumulated and parsed during this chunk. May be
  /// empty when the chunk contained no tag.
  final List<ToolCall> calls;
}

/// Stream-time parser that pulls `<TOOL_CALL>{...}</TOOL_CALL>` blocks
/// out of a chunked LLM reply.
///
/// The parser is intentionally conservative:
///
/// - **Tail withholding:** in `text` mode the last `_openTag.length`
///   characters of every fed chunk are held back from `cleanedText`,
///   so a tag whose `<TOOL_CALL>` opener is split across two chunks
///   never leaks into the transcript before we identify it.
/// - **Bounded tag buffer:** if no `</TOOL_CALL>` close arrives within
///   [_maxTagBufferChars] of an opener, we abandon the tag, splice the
///   buffered content back into `cleanedText`, and return to `text`
///   mode. Keeps a runaway model that emits a giant block of JSON
///   from eating arbitrary memory.
/// - **Idempotent flush:** [flush] empties the tail buffer and runs a
///   final regex pass over the accumulated cleaned text to catch tool
///   tags the model emitted *outside* the framing (post-prose JSON).
///   The gateway calls this when the LLM stream completes.
///
/// The parser is single-use; create a fresh instance per turn.
class ToolCallStreamParser {
  static const String _openTag = '<TOOL_CALL>';
  static const String _closeTag = '</TOOL_CALL>';
  static const int _maxTagBufferChars = 4096;

  bool _inTag = false;
  final StringBuffer _tagBuffer = StringBuffer();

  /// Tail buffer: characters held back from `cleanedText` because they
  /// might be the prefix of an `_openTag`.
  String _tail = '';

  /// Full cleaned text emitted so far, kept so [flush] can run a final
  /// fallback regex over it.
  final StringBuffer _cleanedSoFar = StringBuffer();

  /// Cleared on every [feed] call; collects tags closed during that
  /// chunk. We expose them only via [ToolParseChunk] so the caller
  /// can dispatch in stream order.
  final List<String> _pendingPayloads = <String>[];

  /// Feed one streamed chunk. Returns the cleaned slice of [chunk]
  /// suitable for transcript display + TTS, plus any [ToolCall]s that
  /// closed inside this chunk.
  ToolParseChunk feed(String chunk) {
    if (chunk.isEmpty) {
      return const ToolParseChunk(cleanedText: '', calls: <ToolCall>[]);
    }

    _pendingPayloads.clear();
    final emit = StringBuffer();

    // Combine any prior tail with the new chunk so cross-chunk tag
    // openers and closers are visible to the loop below.
    var work = _tail + chunk;
    _tail = '';

    while (work.isNotEmpty) {
      if (_inTag) {
        final close = work.indexOf(_closeTag);
        if (close < 0) {
          // No closer yet — buffer the whole work string and bail.
          _tagBuffer.write(work);
          if (_tagBuffer.length > _maxTagBufferChars) {
            _abandonTag(emit);
          }
          work = '';
        } else {
          _tagBuffer.write(work.substring(0, close));
          _pendingPayloads.add(_tagBuffer.toString());
          _tagBuffer.clear();
          _inTag = false;
          work = work.substring(close + _closeTag.length);
        }
        continue;
      }

      // text mode
      final open = work.indexOf(_openTag);
      if (open >= 0) {
        if (open > 0) {
          emit.write(work.substring(0, open));
        }
        _inTag = true;
        work = work.substring(open + _openTag.length);
        continue;
      }

      // No full opener found in `work`. Hold back the last
      // `_openTag.length - 1` chars in case they're a partial opener
      // straddling the next chunk; emit the rest.
      const keep = _openTag.length - 1;
      if (work.length <= keep) {
        _tail = work;
        work = '';
      } else {
        emit.write(work.substring(0, work.length - keep));
        _tail = work.substring(work.length - keep);
        work = '';
      }
    }

    final cleaned = emit.toString();
    if (cleaned.isNotEmpty) {
      _cleanedSoFar.write(cleaned);
    }
    final calls = <ToolCall>[];
    for (final payload in _pendingPayloads) {
      final c = ToolCall.tryParse(payload);
      if (c != null) calls.add(c);
    }
    _pendingPayloads.clear();
    return ToolParseChunk(cleanedText: cleaned, calls: calls);
  }

  /// Drain the parser at end-of-stream. Returns any leftover cleaned
  /// text (the held-back tail) and any tool calls recovered by the
  /// post-parse regex fallback.
  ToolParseChunk flush() {
    final leftover = StringBuffer();
    final calls = <ToolCall>[];

    if (_inTag) {
      final buffered = _tagBuffer.toString();
      if (buffered.isNotEmpty) {
        final json = ToolCallExtractor._extractBalancedJson(buffered, 0);
        if (json != null) {
          final c = ToolCall.tryParse(json);
          if (c != null) {
            calls.add(c);
          } else {
            leftover
              ..write(_openTag)
              ..write(json);
          }
        } else {
          leftover
            ..write(_openTag)
            ..write(buffered);
        }
      }
      _tagBuffer.clear();
      _inTag = false;
    }
    if (_tail.isNotEmpty) {
      leftover.write(_tail);
      _tail = '';
    }

    final leftoverStr = leftover.toString();
    if (leftoverStr.isNotEmpty) {
      _cleanedSoFar.write(leftoverStr);
    }

    // Fallback over the full cleaned buffer — closed tags, unclosed
    // JSON payloads, and anything the stream parser deferred.
    for (final c in ToolCallExtractor.extractFromText(
      _cleanedSoFar.toString(),
    )) {
      calls.add(c);
    }

    return ToolParseChunk(cleanedText: leftoverStr, calls: calls);
  }

  void _abandonTag(StringBuffer emit) {
    // Splice the buffered tag content back into the transcript so the
    // model's output isn't silently truncated.
    emit
      ..write(_openTag)
      ..write(_tagBuffer.toString());
    _tagBuffer.clear();
    _inTag = false;
  }
}
