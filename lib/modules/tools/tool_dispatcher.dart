import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/session_log.dart';
import 'tool_call.dart';
import 'tool_invocation.dart';

/// Side-effect contract a single tool implementation must honor.
///
/// Tools are always invoked through [ToolDispatcher.execute]; they
/// never own their own dispatcher entry point. The dispatcher gives
/// them an [onUpdate] callback they fire whenever the [ToolInvocation]
/// state changes (status flips, label updates, alert haptics, etc.) —
/// the dispatcher then re-broadcasts the full invocation list so the
/// UI re-renders.
abstract class ToolHandler {
  /// Stable name. Must match the JSON `name` Gemma emits in its
  /// `<TOOL_CALL>` tag and the manual-row buttons.
  String get name;

  /// Spin up the side-effect for [invocation]. Implementations should
  /// flip [invocation.status] from `pending` → `running` themselves
  /// (the dispatcher only seeds it as `pending`) and call [onUpdate]
  /// after every observable mutation.
  ///
  /// Implementations MUST return promptly — long-running side-effects
  /// (continuous vibration, timer loops) belong on internal `Timer`s
  /// or async loops fired from inside this method, not awaited here.
  Future<void> start(ToolInvocation invocation, void Function() onUpdate);

  /// Cancel the side-effect for [invocation]. Idempotent — the
  /// dispatcher may call this on an already-completed invocation
  /// during `stopAll` / `dispose`.
  Future<void> stop(ToolInvocation invocation);

  /// Build the human-readable label the tray card renders. Pulled out
  /// of [start] so the dispatcher can compose the `ToolInvocation`
  /// before any side-effect actually fires (UX: the card appears the
  /// instant the model emits the tag, not after the first vibration
  /// pulse lands).
  String labelFor(ToolCall call);
}

/// Central registry + executor for the agentic tool layer.
///
/// One dispatcher per app instance, owned by [EmergencyUI]. Both the
/// audio gateway (model-driven) and the manual TOOLS row in
/// [AudioUI] (responder-driven) call [execute] with the same
/// [ToolCall] shape — there is no separate "manual" code path.
///
/// Concurrency rules:
///   - At most one running invocation per tool [name]. Submitting a
///     fresh CPR cadence supersedes a prior CPR cadence; the prior
///     vibration stops within ~100 ms.
///   - **Exception:** `medical_timer` is allowed unlimited concurrent
///     invocations because the responder may have a tourniquet timer
///     AND a re-assess timer running side by side.
class ToolDispatcher {
  ToolDispatcher({required Map<String, ToolHandler> handlers})
      : _handlers = Map<String, ToolHandler>.unmodifiable(handlers);

  /// Tool names that may run concurrently. Any tool NOT in this set
  /// gets at-most-one semantics (a fresh invocation cancels the prior
  /// invocation of the same name before starting).
  static const Set<String> _concurrentNames = <String>{'medical_timer'};

  final Map<String, ToolHandler> _handlers;
  final List<ToolInvocation> _invocations = <ToolInvocation>[];
  final StreamController<List<ToolInvocation>> _ctrl =
      StreamController<List<ToolInvocation>>.broadcast();

  bool _disposed = false;

  /// Live snapshot stream. Re-emits the full active+recent list on every
  /// state change. The UI tray subscribes here.
  Stream<List<ToolInvocation>> get invocations => _ctrl.stream;

  /// Synchronous view of the current invocation list (active +
  /// recently-finished). Useful for first-frame render before the
  /// stream has fired.
  List<ToolInvocation> get current =>
      List<ToolInvocation>.unmodifiable(_invocations);

  /// Names of tools the dispatcher knows about. Used by the audio
  /// gateway when it needs to decide whether a parsed tag is worth
  /// dispatching at all.
  Iterable<String> get registeredNames => _handlers.keys;

  /// Run [call]. Returns the [ToolInvocation] in either `running` or
  /// `error` state — the future does not wait for the side-effect to
  /// complete.
  Future<ToolInvocation> execute(ToolCall call) async {
    if (_disposed) {
      return _errorInvocation(call, 'Dispatcher disposed.');
    }

    final handler = _handlers[call.name];
    if (handler == null) {
      final inv = _errorInvocation(call, 'Unknown tool: ${call.name}');
      _invocations.add(inv);
      _emit();
      return inv;
    }

    // At-most-one semantics for non-concurrent tool names. We do this
    // BEFORE constructing the new invocation so the tray flips from
    // "old running" to "new running" in a single tick.
    if (!_concurrentNames.contains(call.name)) {
      await _stopActiveByName(call.name);
    }

    final invocation = ToolInvocation(
      call: call,
      label: handler.labelFor(call),
      status: ToolStatus.pending,
      startedAt: DateTime.now(),
    );
    _invocations.add(invocation);
    _emit();

    await SessionLog.instance?.agenticCall(call.name);
    try {
      await handler.start(invocation, _emit);
      await SessionLog.instance?.toolExecuted(
        '${call.name} ${invocation.status.name}',
      );
    } catch (e, st) {
      debugPrint('ToolDispatcher: handler $invocation threw: $e\n$st');
      invocation.status = ToolStatus.error;
      invocation.errorMessage = e.toString();
      _emit();
      await SessionLog.instance?.toolExecuted(
        '${call.name} error',
      );
    }
    return invocation;
  }

  /// Stop a single invocation by id. Idempotent.
  Future<void> stop(String invocationId) async {
    final inv = _findActive(invocationId);
    if (inv == null) return;
    final handler = _handlers[inv.name];
    if (handler != null) {
      try {
        await handler.stop(inv);
      } catch (e) {
        debugPrint('ToolDispatcher.stop($invocationId) failed: $e');
      }
    }
    if (inv.status == ToolStatus.pending || inv.status == ToolStatus.running) {
      inv.status = ToolStatus.cancelled;
    }
    _emit();
    await SessionLog.instance?.toolExecuted('${inv.name} cancelled');
  }

  /// Stop every active invocation. Wired into `AudioGateway.reset` and
  /// `suspendForExternalInference`, plus `EmergencyUI.dispose`.
  Future<void> stopAll() async {
    final actives = _invocations.where((i) => i.isActive).toList();
    for (final inv in actives) {
      await stop(inv.id);
    }
  }

  /// Tear-down. After this, [execute] short-circuits to error
  /// invocations.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopAll();
    await _ctrl.close();
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  Future<void> _stopActiveByName(String name) async {
    final actives = _invocations
        .where((i) => i.name == name && i.isActive)
        .toList();
    for (final inv in actives) {
      await stop(inv.id);
    }
  }

  ToolInvocation? _findActive(String id) {
    for (final inv in _invocations) {
      if (inv.id == id) return inv;
    }
    return null;
  }

  ToolInvocation _errorInvocation(ToolCall call, String message) {
    return ToolInvocation(
      call: call,
      label: call.name,
      status: ToolStatus.error,
      startedAt: DateTime.now(),
      errorMessage: message,
    );
  }

  void _emit() {
    if (_disposed || _ctrl.isClosed) return;
    _ctrl.add(List<ToolInvocation>.unmodifiable(_invocations));
  }
}
