import 'dart:convert';

/// A single agentic tool invocation requested either by Gemma (via a
/// `<TOOL_CALL>{...}</TOOL_CALL>` tag emitted into its reply stream) or
/// by the responder tapping a manual button on the ASK screen. Both
/// paths converge on this struct + [ToolDispatcher.execute].
///
/// Args are deliberately stored as a loose [Map] of JSON-decoded values
/// rather than per-tool typed configs, because:
///   - the model's args section is JSON in practice (we asked it for
///     JSON in the system prompt) and we want a wide tolerance for
///     missing / superfluous keys;
///   - each tool's handler does its own clamp / default / coerce when
///     unpacking the args, keeping the strictness near the side-effect.
class ToolCall {
  ToolCall({
    required this.name,
    required this.args,
    String? id,
  }) : id = id ?? _mintId();

  /// Stable per-invocation id. Used by the UI to address the running
  /// tool (e.g. STOP buttons) and by the gateway to attach
  /// `toolInvocationIds` to the streaming model turn.
  final String id;

  /// Tool name. Must match a [ToolDispatcher] handler key, otherwise
  /// dispatch surfaces an error invocation rather than throwing.
  final String name;

  /// Tool-specific args, loosely typed. Tool implementations are
  /// expected to apply their own clamps and defaults — see
  /// [_intArg] / [_listIntArg] / [_stringArg] in the individual tools.
  final Map<String, Object?> args;

  /// Best-effort JSON parser. Returns `null` (rather than throwing) on
  /// any malformed input so the gateway can keep streaming the rest of
  /// the model's reply when Gemma emits a half-formed tag. The gateway
  /// logs the rejected payload via `debugPrint` for postmortem.
  static ToolCall? tryParse(String rawJson) {
    final trimmed = rawJson.trim();
    if (trimmed.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final map = decoded.cast<String, Object?>();
    final name = map['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final rawArgs = map['args'];
    Map<String, Object?> args = const <String, Object?>{};
    if (rawArgs is Map) {
      args = rawArgs.cast<String, Object?>();
    }
    return ToolCall(name: name.trim(), args: args);
  }

  static int _seq = 0;
  static String _mintId() {
    _seq = (_seq + 1) & 0x7fffffff;
    return 'tc_${DateTime.now().microsecondsSinceEpoch}_$_seq';
  }

  @override
  String toString() => 'ToolCall($name, args=$args, id=$id)';
}
