import '../../database/medical_kb.dart';
import '../vision/vision_result.dart' show KbCitation;

/// The role that produced a [ConversationTurn].
enum TurnRole {
  /// Spoken question from the user (produced by Gemma's audio tower
  /// after ASR, plus optional manual edits).
  user,

  /// Model-produced reply.
  model,

  /// System-level message (e.g. "Conversation reset").
  system,
}

/// A single entry in the audio-gateway transcript.
///
/// The UI renders one card per turn. [isStreaming] is true for the
/// in-flight model reply while tokens are still arriving; the card
/// re-renders as [text] grows.
class ConversationTurn {
  ConversationTurn({
    required this.role,
    required this.text,
    this.isStreaming = false,
    this.detectedLanguage,
    this.grounded = false,
    this.citations = const <KbCitation>[],
    this.protocols = const <ProtocolHit>[],
    this.warnings = const <String>[],
    this.toolInvocationIds = const <String>[],
  });

  final TurnRole role;
  final String text;
  final bool isStreaming;

  /// Whisper-inferred language for this user utterance (`ur`, `en`, …).
  final String? detectedLanguage;

  /// True when [citations] / [protocols] backed the reply. Same
  /// "KB VERIFIED" pattern the vision result uses.
  final bool grounded;
  final List<KbCitation> citations;
  final List<ProtocolHit> protocols;

  /// Short, human-readable caveats to render above the body text
  /// (e.g. "No local protocol match — verify before acting").
  final List<String> warnings;

  /// Ids of [ToolInvocation]s the gateway dispatched while streaming
  /// this turn. The transcript card uses these to render a "Tools
  /// fired:" footer that links back to the tray, so the responder can
  /// see exactly which agentic side-effects this reply triggered.
  /// Empty for pre-existing model turns; populated by the audio
  /// gateway as it parses `<TOOL_CALL>` tags out of the stream.
  final List<String> toolInvocationIds;

  ConversationTurn copyWith({
    String? text,
    bool? isStreaming,
    String? detectedLanguage,
    bool? grounded,
    List<KbCitation>? citations,
    List<ProtocolHit>? protocols,
    List<String>? warnings,
    List<String>? toolInvocationIds,
  }) {
    return ConversationTurn(
      role: role,
      text: text ?? this.text,
      isStreaming: isStreaming ?? this.isStreaming,
      detectedLanguage: detectedLanguage ?? this.detectedLanguage,
      grounded: grounded ?? this.grounded,
      citations: citations ?? this.citations,
      protocols: protocols ?? this.protocols,
      warnings: warnings ?? this.warnings,
      toolInvocationIds: toolInvocationIds ?? this.toolInvocationIds,
    );
  }
}
