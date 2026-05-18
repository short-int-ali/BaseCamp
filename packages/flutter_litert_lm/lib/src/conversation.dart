import '../flutter_litert_lm_platform_interface.dart';
import 'content.dart';
import 'message.dart';

/// A conversation session with a loaded LLM model.
///
/// Use [LiteLmEngine.createConversation] to obtain an instance.
/// Remember to call [dispose] when done.
class LiteLmConversation {
  final String _id;
  bool _disposed = false;

  LiteLmConversation._(this._id);

  /// Internal factory — called by engine.
  static LiteLmConversation fromId(String id) => LiteLmConversation._(id);

  /// The native conversation ID.
  String get id => _id;

  /// Send a text message and get the complete response.
  Future<LiteLmMessage> sendMessage(
    String text, {
    Map<String, Object>? extraContext,
  }) async {
    _ensureNotDisposed();
    final contents = [LiteLmContent.text(text).toMap()];
    final result = await FlutterLitertLmPlatform.instance.sendMessage(
      _id,
      contents,
      extraContext,
    );
    return LiteLmMessage.fromMap(result);
  }

  /// Send multimodal contents (text + images + audio) and get the complete response.
  Future<LiteLmMessage> sendMultimodalMessage(
    List<LiteLmContent> contents, {
    Map<String, Object>? extraContext,
  }) async {
    _ensureNotDisposed();
    final result = await FlutterLitertLmPlatform.instance.sendMessage(
      _id,
      contents.map((c) => c.toMap()).toList(),
      extraContext,
    );
    return LiteLmMessage.fromMap(result);
  }

  /// Send a text message and stream back partial responses as tokens are generated.
  Stream<LiteLmMessage> sendMessageStream(
    String text, {
    Map<String, Object>? extraContext,
  }) {
    _ensureNotDisposed();
    final contents = [LiteLmContent.text(text).toMap()];
    return FlutterLitertLmPlatform.instance
        .sendMessageStream(_id, contents, extraContext)
        .map((map) => LiteLmMessage.fromMap(map));
  }

  /// Send multimodal contents (text + images + audio) and stream back
  /// partial responses as tokens are generated.
  ///
  /// Local fork extension: upstream 0.3.0 only exposes the text-only
  /// [sendMessageStream]. The audio gateway needs this variant because
  /// Gemma 4's audio tower does ASR + understanding in a single
  /// forward pass — we feed `[AudioBytes, Text]` and stream the
  /// model's reply one token at a time.
  Stream<LiteLmMessage> sendMultimodalMessageStream(
    List<LiteLmContent> contents, {
    Map<String, Object>? extraContext,
  }) {
    _ensureNotDisposed();
    return FlutterLitertLmPlatform.instance
        .sendMessageStream(
          _id,
          contents.map((c) => c.toMap()).toList(),
          extraContext,
        )
        .map((map) => LiteLmMessage.fromMap(map));
  }

  /// Send a tool response back to the model.
  Future<LiteLmMessage> sendToolResponse(
    String toolName,
    String result, {
    Map<String, Object>? extraContext,
  }) async {
    _ensureNotDisposed();
    final contents = [LiteLmContent.toolResponse(toolName, result).toMap()];
    final response = await FlutterLitertLmPlatform.instance.sendMessage(
      _id,
      contents,
      extraContext,
    );
    return LiteLmMessage.fromMap(response);
  }

  /// Release native resources for this conversation.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await FlutterLitertLmPlatform.instance.disposeConversation(_id);
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('Conversation has been disposed');
    }
  }
}
