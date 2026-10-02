import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../protocol/automation.dart';
import '../protocol/connection_params.dart';
import '../protocol/conversation.dart';
import '../protocol/off_peak.dart';
import '../protocol/relay_client.dart';
import '../protocol/remote_client.dart';
import '../protocol/task_commands.dart';
import 'device_store.dart';

/// Mirrors `HC()` in the web client:
/// key = workspaceIdentity?.trim() || workspacePath.
String? workspaceKeyOf(Map<String, dynamic> w) {
  final identity = w['workspaceIdentity'];
  if (identity is String && identity.trim().isNotEmpty) {
    return identity.trim();
  }
  final path = w['workspacePath'];
  if (path is String && path.isNotEmpty) return path;
  for (final key in const ['workspaceKey', 'key', 'id']) {
    final v = w[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

String workspaceTitle(Map<String, dynamic> w) {
  final label = w['label'] as String?;
  if (label != null && label.isNotEmpty) return label;
  final path = w['workspacePath'] as String?;
  if (path != null && path.isNotEmpty) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.lastWhere((p) => p.isNotEmpty, orElse: () => path);
  }
  final identity = w['workspaceIdentity'] as String?;
  if (identity != null && identity.isNotEmpty) return identity;
  return workspaceKeyOf(w) ?? '?';
}

/// Health-gated workspace RPC surface behind [DeviceSession.callChannel].
///
/// The default implementation wraps the live bridge; tests inject a fake
/// through [DeviceSession.debugAttachGateForTest] to drive the
/// stall→rebuild policy without sockets.
abstract interface class WorkspaceGate {
  Future<void> waitHealthy({required Duration timeout});
  Future<dynamic> call(String channel, String method, List<Object?> args);
}

class _LiveWorkspaceGate implements WorkspaceGate {
  final BridgeSession bridge;
  _LiveWorkspaceGate(this.bridge);

  @override
  Future<void> waitHealthy({required Duration timeout}) =>
      bridge.waitHealthy(timeout: timeout);

  @override
  Future<dynamic> call(String channel, String method, List<Object?> args) =>
      bridge.channels.call(channel, method, args);
}

/// Tunable durations of [DeviceSession]'s stall defenses. Production uses
/// the default; tests shrink them to drive the policy with real short
/// delays instead of a fake clock.
class StallTimings {
  /// Gate bound while a channel RPC waits on a degraded bridge; on expiry
  /// the link counts as wedged and a full rebuild is forced (the cold-start
  /// permanent-loading defence).
  final Duration healthyWaitTimeout;

  /// Hard cap for one channel RPC after the gate passes.
  final Duration rpcTimeout;

  /// Bound for a single relay dial (`socket.ready` has no internal timeout
  /// and can otherwise park `connect` forever).
  final Duration dialTimeout;

  /// How long the sessions-index may stay un-ready on a connected session
  /// before the list watchdog escalates (reopen once, then rebuild).
  final Duration listReadyTimeout;

  /// Minimum spacing between forced rebuilds so probe storms can't thrash.
  final Duration minRebuildInterval;

  /// Delay between automatic retries after a retryable connect failure.
  final Duration retryBackoff;

  const StallTimings({
    this.healthyWaitTimeout = const Duration(seconds: 12),
    this.rpcTimeout = const Duration(seconds: 30),
    this.dialTimeout = const Duration(seconds: 30),
    this.listReadyTimeout = const Duration(seconds: 20),
    this.minRebuildInterval = const Duration(seconds: 30),
    this.retryBackoff = const Duration(seconds: 30),
  });
}

enum DeviceStatus { disconnected, connecting, connected, error }

/// What the automations UI needs from a device link: live status plus the
/// automation port. [DeviceSession] implements this; tests fake it.
abstract interface class AutomationHost {
  DeviceStatus get status;
  AutomationPort get automation;

  /// Active workspace scope (`workspacePath`/`workspaceIdentity`) attached
  /// to run-now triggers; the desktop requires it server-side.
  Map<String, dynamic> get automationScope;
}

/// Same for the off-peak UI: live status, the off-peak port and the
/// workspace scope the submitted run binds to.
abstract interface class OffPeakHost {
  DeviceStatus get status;
  OffPeakPort get offPeak;

  /// `workspacePath` (+ identity) of the active workspace for submissions.
  Map<String, dynamic> get offPeakScope;

  /// Official model-selection view backing the form's model picker
  /// (`model-selection` getView); empty when unavailable — the form then
  /// falls back to prepareWorkspace options.
  Future<List<OffPeakModelChoice>> modelSelectionView();
}

/// A device link the notification hub can observe: live task phases plus
/// the automation / off-peak ports. [DeviceSession] implements this.
abstract interface class NotifiableSession
    implements AutomationHost, OffPeakHost, Listenable {
  String get deviceId;
  @override
  DeviceStatus get status;
  SessionsIndexState? get sessions;
}

/// A live conversation subscription handed to the chat UI: [state] is the
/// live rows/snapshot notifier, [close] unsubscribes.
class ChatHandle {
  final ConversationState state;
  final Future<void> Function() close;

  const ChatHandle({required this.state, required this.close});
}

/// The Conversation V4 surface the native chat page drives — the
/// [AutomationHost]/[OffPeakHost] seam pattern applied to conversations.
/// [DeviceSession] implements it against the live transport; tests fake it
/// (recording calls, answering from a real [ConversationState] fed by hand).
abstract interface class ChatGateway implements Listenable {
  DeviceStatus get status;
  bool get kicked;
  String? get error;

  /// Task metadata commands (rename/pin/archive/unread). Method names are
  /// source-confirmed — see [TaskCommandsPort].
  Future<dynamic> renameTask(String sessionId, String title);
  Future<dynamic> setTaskPinned(String sessionId, bool pinned);
  Future<dynamic> setTaskArchived(String sessionId, bool archived);
  Future<dynamic> setTaskUnread(String sessionId, bool unread);

  /// Deletes a task (`zcode-task.deleteTask`). Callers confirm first.
  Future<dynamic> deleteTask(String sessionId);

  /// mobile-view-state-update: report the task the chat UI is showing
  /// (or just the workspace when [taskId] is null).
  void sendViewState({String? taskId});

  /// `workspaceId` for draft-mode createSession, plus the workspace path
  /// for the chat page's copy action.
  String? get chatWorkspaceId;
  String? get workspacePath;

  /// Original remote-control URL (for "copy task link").
  String? get remoteUrl;

  /// Manual recovery after a KICK: full suspend + reconnect.
  Future<void> reconnect();

  Future<ChatHandle> subscribe(String sessionId);
  Future<WorkspacePrep> prepareWorkspace();
  Future<List<SkillEntry>> skills();

  Future<String> createSession(
    String workspaceId, {
    String? firstText,
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic>? config,
  });

  Future<dynamic> sendText(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
  });

  Future<dynamic> sendGoalCommand(
    String sessionId,
    String text, {
    String? heldQueueDisposition,
  });

  Future<dynamic> stop(String sessionId);
  Future<dynamic> compact(String sessionId);
  Future<dynamic> pauseGoal(String sessionId);
  Future<dynamic> resumeGoal(String sessionId);

  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  });

  Future<dynamic> switchCollaborationMode(String sessionId, String mode);
  Future<dynamic> setFollowupMode(String sessionId, String mode);
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  );
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  });

  /// Trusts the selected workspace hooks (web respondWorkspaceHookReview;
  /// the interaction payload carries the full command target).
  Future<dynamic> respondWorkspaceHookReview(
    String sessionId,
    Map payload,
    List<String> reviewItemIds,
  );

  /// Coding-plan entitlement snapshot (usage-stats bridge channel) backing
  /// the session quota banner. Returns null when the desktop rejects it.
  Future<Map<String, dynamic>?> usageEntitlement();

  /// Resumes a stopped/failed workflow run (workId ≡ runId; the CLI's
  /// `resumable` bit gates the button, the command can still be rejected).
  Future<dynamic> resumeWorkflowRun(String sessionId, String runId,
      {String? name});

  /// Workflow run artifact summaries (web workflowRunArtifacts); empty
  /// when the desktop rejects the call.
  Future<List<Map<String, dynamic>>> runArtifacts(String sessionId, String runId);

  /// Preset-board items (web workflowRunArtifactData).
  Future<List<Map<String, dynamic>>> runArtifactData(
    String sessionId,
    String runId,
    String artifactId,
  );

  /// Full artifact bytes, chunked over workflowRunArtifactRead (512KiB per
  /// chunk, bounded); null when the desktop rejects the call.
  Future<({Uint8List bytes, String? mediaType})?> runArtifactBytes(
    String sessionId,
    String runId,
    Map<String, dynamic> artifact,
  );

  Future<dynamic> rowsRange(String sessionId, {int? beforeRowId, int limit});

  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  });

  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  });

  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId);
  Future<dynamic> editQueueItem(
    String sessionId,
    String queueItemId,
    String newText,
  );
  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId);
  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain);
  Future<dynamic> reorderQueueItem(
    String sessionId,
    String queueItemId,
    String? beforeQueueItemId,
  );

  /// Defers the interaction auto-resolution (「提问自动继续」timer).
  Future<dynamic> snoozeInteraction(String sessionId, String interactionId);

  /// Cancels a background work item (terminal / subagent banner ✕).
  Future<dynamic> cancelBackgroundWork(String sessionId, String workId);

  /// Deletes the whole session (confirm in the UI first).
  Future<dynamic> deleteSession(String sessionId);
  Future<dynamic> plans(String sessionId);
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  });
  Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target);
  Future<dynamic> forkAssistant(String sessionId, Map<String, dynamic> target);
  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText,
  );
  Future<dynamic> applyFileRewind(
    String sessionId,
    Map<String, dynamic> target,
  );

  /// Precheck for a rewind (conversationFileRewindPreviewV4).
  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
  });

  /// @-mention data sources (web chat.mention.* picker).
  /// Files of the active workspace: {name, path, relativePath, type}.
  Future<List<Map<String, dynamic>>> mentionFiles();

  /// Skills (id/name/description) — same data as the $ picker.
  Future<List<Map<String, dynamic>>> mentionSkills();

  /// Subagents (name/description); empty on desktops rejecting the call.
  Future<List<Map<String, dynamic>>> mentionSubagents();

  /// Open sessions of the active workspace (id/title).
  List<({String id, String title})> mentionSessions();

  /// Skills synchronously from the last known list (mention picker reads
  /// this without awaiting a fresh RPC).
  List<Map<String, dynamic>> mentionSkillsSync();
}

/// One native protocol connection to one device. Owns the full stack
/// (relay → bridge → conversation → sessions-index) and exposes just what
/// the native UI needs: online status, the live task list and task
/// commands.
///
/// Lifecycle notes (verified against the live server):
/// - A device (same sid) allows exactly ONE terminal connection. Before
///   handing the device over to the WebView, [suspend] must close this
///   connection cleanly, otherwise the WebView auth kicks us (or vice
///   versa).
/// - Being KICKED by another terminal is terminal for this session: no
///   auto-reconnect (the relay already suppresses it).
class DeviceSession extends ChangeNotifier
    implements AutomationHost, OffPeakHost, NotifiableSession, ChatGateway {
  @override
  final String deviceId;
  final RemoteConnectionParams params;

  /// Last workspace this device showed (hub memory; survives WebView
  /// handovers within one app run).
  final String? preferredWorkspaceKey;
  final void Function(String workspaceKey)? onWorkspaceOpened;

  /// Test seam: replaces the default [RemoteClient] construction in
  /// [connect]; production keeps the real relay-backed client.
  @visibleForTesting
  final RemoteClient Function()? clientFactory;

  /// Tunable stall-defense durations (tests shrink the defaults).
  @visibleForTesting
  final StallTimings timings;

  DeviceSession({
    required this.deviceId,
    required this.params,
    this.preferredWorkspaceKey,
    this.onWorkspaceOpened,
    this.clientFactory,
    this.timings = const StallTimings(),
  });

  RemoteClient? _client;
  BridgeSession? _bridge;
  ConversationTransport? _conversation;
  SessionsIndexSubscription? _sessionsSub;
  final Map<String, ConversationSubscription> _chatSubs = {};
  StreamSubscription? _failureSub;
  StreamSubscription? _wsListSub;
  StreamSubscription? _appErrSub;
  Timer? _retryTimer;
  Timer? _listWatchdog;
  int _retryAttempts = 0;

  // --- Stall bookkeeping (cold-start permanent-loading defence) ---
  /// Consecutive soft reloads (bootstrap/open) that produced no progress.
  int _softReloadFails = 0;

  /// List-watchdog escalation step: 0 idle; 1 = reopen once failed.
  int _listEscalations = 0;

  /// Wall clock of the last forced rebuild, for debouncing.
  DateTime _lastStallRebuildAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _rebuilding = false;

  /// Test seam overriding the live bridge gate in [callChannel].
  WorkspaceGate? _testGate;

  bool _disposed = false;
  bool _connecting = false;
  bool _openingWorkspace = false;
  bool _kicked = false;
  String? _error;

  DeviceStatus _status = DeviceStatus.disconnected;
  List<Map<String, dynamic>> _workspaces = [];
  Map<String, dynamic>? _activeWorkspace;

  /// Relay-level task list (`Dg` model from bootstrap /
  /// workspace-list-updated): every workspace's tasks with
  /// displayStatus/pinned/archived/unreadAt. The web mobile home renders
  /// non-active workspaces (and the archive view) from exactly this list.
  List<Map<String, dynamic>> _relayTasks = [];

  /// Well-known `app-error` reason of the last fatal failure (mirrors the
  /// web's `webRemoteControl.failure.*` enum); UI maps it to localized copy.
  String? _failureReason;

  @override
  DeviceStatus get status => _status;
  @override
  bool get kicked => _kicked;
  @override
  String? get error => _error;

  /// Reason code (`session-not-found`, `session-conflict`,
  /// `unsupported-action`, ...) of the current failure, if any.
  String? get failureReason => _failureReason;

  /// Relay task list (raw `Dg` maps).
  List<Map<String, dynamic>> get relayTasks => _relayTasks;

  /// True while a workspace bridge + sessions-index open is in flight.
  bool get openingWorkspace => _openingWorkspace;

  /// Workspaces reported by bootstrap (raw maps).
  List<Map<String, dynamic>> get workspaces => _workspaces;
  Map<String, dynamic>? get activeWorkspace => _activeWorkspace;

  /// Live sessions-index state of the active workspace, if subscribed.
  @override
  SessionsIndexState? get sessions => _sessionsSub?.state;

  /// Conversation transport of the active workspace (chat UI seam).
  ConversationTransport? get conversation => _conversation;

  /// Workspace bridge of the active workspace.
  BridgeSession? get bridge => _bridge;

  /// Sessions with phase running/prewarming — the card badge count.
  int get runningTaskCount =>
      sessions?.list
          .where((e) => e.phase == 'running' || e.phase == 'prewarming')
          .length ??
      0;

  bool get _busy => _connecting;

  /// Connects and subscribes the sessions-index. Safe to call repeatedly;
  /// a live connection is reused, a retryable failure is re-attempted.
  Future<void> connect() async {
    if (_disposed || _busy || _status == DeviceStatus.connected) return;
    _connecting = true;
    _retryTimer?.cancel();
    _listWatchdog?.cancel();
    _kicked = false;
    _error = null;
    _failureReason = null;
    _setStatus(DeviceStatus.connecting);
    final sw = Stopwatch()..start();
    final client = clientFactory != null
        ? clientFactory!()
        : RemoteClient(params, onLog: _log);
    _failureSub = client.relay.failures.listen(_onRelayFailure);
    try {
      // socket.ready has no internal timeout: a black-holed dial would park
      // connect (and the whole UI) in `connecting` forever.
      await client.connect().timeout(timings.dialTimeout);
      sw.reset();
      await client.waitPaired(timeout: const Duration(seconds: 90));
      _log('[session] paired in ${sw.elapsedMilliseconds}ms');
      if (_disposed) {
        await client.dispose();
        return;
      }
      _client = client;
      client.relay.stateListenable.addListener(_onRelayState);
      _wsListSub = client.workspaceListUpdated.listen(_onWorkspaceListUpdated);
      _appErrSub = client.appErrors.listen(_onAppError);
      _onRelayState();
      sw.reset();
      final bootstrap = await client.bootstrap();
      _log('[session] bootstrap in ${sw.elapsedMilliseconds}ms');
      final list = bootstrap['workspaces'];
      _workspaces = [
        if (list is List)
          for (final w in list)
            if (w is Map) w.cast<String, dynamic>(),
      ];
      final tasks = bootstrap['tasks'];
      _relayTasks = [
        if (tasks is List)
          for (final t in tasks)
            if (t is Map) t.cast<String, dynamic>(),
      ];
      _retryAttempts = 0;
      // Auto-open a workspace so the native list works immediately: the
      // last-used one when known, else the first. (The web mobile flow
      // auto-opens only a single workspace and shows a picker otherwise;
      // here the picker is the fallback, never a blocking spinner.)
      if (_activeWorkspace == null && _workspaces.isNotEmpty) {
        await openWorkspace(_preferredWorkspace ?? _workspaces.first);
      }
      _setStatus(DeviceStatus.connected);
      // Status must read connected before arming: the watchdog only guards
      // the healthy-looking-but-never-ready state.
      _armListWatchdog();
    } catch (e) {
      await _failureSub?.cancel();
      _failureSub = null;
      await _wsListSub?.cancel();
      _wsListSub = null;
      await _appErrSub?.cancel();
      _appErrSub = null;
      if (_disposed) {
        await client.dispose();
        return;
      }
      await client.dispose();
      _error = '$e';
      _log(
        '[session] connect failed after '
        '${sw.elapsedMilliseconds}ms: $e',
      );
      _setStatus(DeviceStatus.error);
      _maybeScheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  /// Failures worth retrying a few times: server unreachable or the
  /// desktop temporarily gone. Credential errors (expired URL, conflict,
  /// kicked) never retry — they need user action.
  void _maybeScheduleRetry() {
    if (_disposed || _kicked) return;
    final msg = _error ?? '';
    final retryable =
        msg.contains('relay-unavailable') ||
        msg.contains('desktop-disconnected') ||
        msg.contains('TimeoutException');
    if (!retryable || _retryAttempts >= 3) return;
    _retryAttempts += 1;
    _retryTimer?.cancel();
    _retryTimer = Timer(timings.retryBackoff, () {
      if (!_disposed && _status == DeviceStatus.error) connect();
    });
  }

  void _onRelayFailure(RelayFailure failure) {
    if (_disposed) return;
    _error = '$failure';
    _failureReason ??= failure.reason;
    _kicked = _kicked || failure.reason == 'kicked';
    if (_kicked) {
      // Another terminal took over; stay quiet until the user acts.
      _retryTimer?.cancel();
    }
    notifyListeners();
  }

  /// Relay push (`workspace-list-updated {result:{workspaces, tasks?, ...}}`):
  /// the live workspace+task overview the web mobile home renders from.
  /// Workspaces merge here; task rows are re-rendered by listeners.
  void _onWorkspaceListUpdated(dynamic result) {
    if (_disposed || result is! Map) return;
    final list = result['workspaces'];
    if (list is List) {
      _workspaces = [
        for (final w in list)
          if (w is Map) w.cast<String, dynamic>(),
      ];
    }
    final tasks = result['tasks'];
    if (tasks is List) {
      _relayTasks = [
        for (final t in tasks)
          if (t is Map) t.cast<String, dynamic>(),
      ];
    }
    notifyListeners();
  }

  /// `app-error` reason → session failure state. session-conflict means the
  /// single mobile slot was taken by another page (web `singlePageNote`
  /// semantics): treated like a kick — no auto-reconnect until the user acts.
  void _onAppError(RemoteAppError e) {
    if (_disposed || _kicked) return;
    _log('[session] app-error ${e.reason}');
    switch (e.reason) {
      case 'session-conflict':
      case 'kicked':
        _kicked = true;
        _failureReason = e.reason;
        _error = e.message;
        _retryTimer?.cancel();
        _setStatus(DeviceStatus.error);
      case 'relay-unavailable':
      case 'desktop-disconnected':
      case 'session-expired':
      case 'workspace-closed':
      case 'session-not-found':
      case 'invalid-mobile-connection':
      case 'desktop-bootstrap-timeout':
      case 'connection-recovery-timeout':
      case 'unsupported-action':
      case 'unexpected-error':
        _failureReason = e.reason;
        _error = e.message;
        _setStatus(DeviceStatus.error);
      default:
        _failureReason = e.reason;
        _error = e.message;
        _setStatus(DeviceStatus.error);
    }
    notifyListeners();
  }

  void _onRelayState() {
    if (_disposed) return;
    switch (_client?.relay.state) {
      case RelayState.paired:
        // Transient reconnects pass through here again; only clear the
        // error banner, sessions state keeps its last snapshot.
        if (_status == DeviceStatus.connecting ||
            _status == DeviceStatus.error) {
          _error = null;
          _setStatus(DeviceStatus.connected);
        }
      case RelayState.connecting:
      case RelayState.authenticating:
      case RelayState.waiting:
      case RelayState.reconnecting:
        if (_status != DeviceStatus.connected) {
          _setStatus(DeviceStatus.connecting);
        }
      case RelayState.kicked:
        _kicked = true;
        _setStatus(DeviceStatus.error);
      case RelayState.error:
        _setStatus(DeviceStatus.error);
      case RelayState.closed:
      case null:
      case RelayState.idle:
        break;
    }
  }

  void _setStatus(DeviceStatus s) {
    if (_status == s) return;
    _status = s;
    notifyListeners();
  }

  /// The workspace matching [preferredWorkspaceKey], if still listed.
  Map<String, dynamic>? get _preferredWorkspace {
    final key = preferredWorkspaceKey;
    if (key == null) return null;
    for (final w in _workspaces) {
      if (workspaceKeyOf(w) == key) return w;
    }
    return null;
  }

  /// Opens (or switches to) a workspace bridge and subscribes its
  /// sessions-index. Switching disposes the previous bridge first.
  ///
  /// Concurrent calls are serialized (last wins) instead of dropped: an
  /// open already in flight used to swallow overlapping retries silently,
  /// which read exactly like the dead "retry" button of the loading bug.
  /// [taskId] rides the `workspace-bridge-open` payload (web parity: tapping
  /// a task of a non-active workspace opens the bridge straight onto it).
  Future<void> openWorkspace(Map<String, dynamic> workspace, {String? taskId}) {
    final previous = _openChain;
    final completer = Completer<void>();
    _openChain = completer;
    () async {
      try {
        if (previous != null) {
          try {
            await previous.future;
          } catch (_) {}
        }
        if (_disposed) return;
        await _openWorkspaceNow(workspace, taskId: taskId);
      } finally {
        if (identical(_openChain, completer)) _openChain = null;
        completer.complete();
      }
    }();
    return completer.future;
  }

  Completer<void>? _openChain;

  Future<void> _openWorkspaceNow(
    Map<String, dynamic> workspace, {
    String? taskId,
  }) async {
    final key = workspaceKeyOf(workspace);
    final client = _client;
    if (key == null || client == null || _disposed || _openingWorkspace) {
      return;
    }
    _openingWorkspace = true;
    final sw = Stopwatch()..start();
    _listWatchdog?.cancel();
    try {
      final bridge = await client.openBridge(key, taskId: taskId);
      if (_disposed || _client != client) {
        bridge.dispose();
        return;
      }
      final oldSub = _sessionsSub;
      final oldBridge = _bridge;
      final oldChats = List.of(_chatSubs.values);
      _sessionsSub = null;
      _conversation = null;
      _chatSubs.clear();
      _bridge = bridge;
      _activeWorkspace = workspace;
      unawaited(oldSub?.dispose());
      for (final s in oldChats) {
        unawaited(s.dispose());
      }
      oldBridge?.dispose();

      final scope = <String, dynamic>{
        'workspacePath': workspace['workspacePath'],
        if (workspace['workspaceIdentity'] != null)
          'workspaceIdentity': workspace['workspaceIdentity'],
      };
      final conversation = bridge.conversation(scope, onLog: _log);
      _conversation = conversation;
      final sub = await conversation.subscribeSessionsIndex();
      if (_disposed || _bridge != bridge) {
        await sub.dispose();
        return;
      }
      _sessionsSub = sub;
      sub.state.addListener(_onSessionsChanged);
      _error = null;
      onWorkspaceOpened?.call(key);
      notifyListeners();
    } catch (e) {
      _log('[session] workspace open failed: $e');
      // The relay link itself is fine; only the native list is degraded —
      // surface the reason so the UI can offer retry / web fallback
      // instead of an eternal spinner.
      _error = '$e';
      notifyListeners();
    } finally {
      _openingWorkspace = false;
      sw.stop();
      // Connected-but-never-ready (open failed OR subscribed with no
      // snapshot yet) is exactly the cold-start loading bug: guard it.
      _armListWatchdog();
    }
  }

  void _onSessionsChanged() {
    if (_disposed) return;
    final sub = _sessionsSub;
    if (sub != null && sub.state.ready) {
      // First snapshot landed — the list is alive again.
      _listWatchdog?.cancel();
      _listEscalations = 0;
      _softReloadFails = 0;
    }
    notifyListeners();
  }

  /// Arms the never-ready watchdog while the task list has no snapshot.
  /// Disarmed instantly by [_onSessionsChanged] once frames arrive, and by
  /// suspend/connect teardowns via the shared cancel points.
  void _armListWatchdog() {
    _listWatchdog?.cancel();
    if (_disposed || status != DeviceStatus.connected) return;
    final sub = _sessionsSub;
    if (sub != null && sub.state.ready) return;
    if (_activeWorkspace == null &&
        _preferredWorkspace == null &&
        _workspaces.isEmpty) {
      // Desktop reports no workspaces: an empty list IS the ready state.
      return;
    }
    _log(
      '[session] list not ready; watchdog armed '
      '(${timings.listReadyTimeout.inSeconds}s)',
    );
    _listWatchdog = Timer(timings.listReadyTimeout, _onListNotReady);
  }

  void _onListNotReady() {
    if (_disposed || _kicked || status != DeviceStatus.connected) return;
    final sub = _sessionsSub;
    if (sub != null && sub.state.ready) return;
    _listEscalations += 1;
    final target =
        _activeWorkspace ?? _preferredWorkspace ?? _workspaces.firstOrNull;
    if (target == null) return;
    if (_listEscalations == 1) {
      // Soft escalation: a fresh bridge + subscribe usually recovers a
      // snapshot lost between the subscribe ack and its delivery.
      _log(
        '[session] sessions-index never became ready; reopening '
        'workspace (soft)',
      );
      unawaited(_reopenForWatchdog(target));
      return;
    }
    final scheduled = _forceRebuildAfterStall(
      'sessions-index still not ready after reopen',
    );
    if (!scheduled && !_disposed && !_kicked) {
      // Rebuild was debounced (one just ran); keep guarding until its
      // outcome lands instead of going silent forever.
      _listWatchdog = Timer(timings.listReadyTimeout, _onListNotReady);
    }
  }

  Future<void> _reopenForWatchdog(Map<String, dynamic> target) async {
    try {
      await openWorkspace(target);
    } finally {
      if (!_disposed) _armListWatchdog();
    }
  }

  /// The link wedged even though [status] may still read connected. Soft
  /// retries would queue on the same dead bridge forever (the reported
  /// "retry does nothing" symptom), so drop the whole stack and reconnect.
  /// Debounced so parallel probe failures rebuild at most once per window.
  /// Returns whether a rebuild was actually scheduled.
  bool _forceRebuildAfterStall(String reason) {
    if (_disposed || _kicked || _rebuilding) return false;
    final now = clock.now();
    if (now.difference(_lastStallRebuildAt) < timings.minRebuildInterval) {
      return false;
    }
    _lastStallRebuildAt = now;
    _rebuilding = true;
    _log('[session] link stalled ($reason); rebuilding connection');
    unawaited(() async {
      await suspend();
      _rebuilding = false;
      if (!_disposed && !_kicked) {
        await connect();
      }
    }());
    return true;
  }

  /// Task-list retry. Soft by design (re-runs bootstrap and re-opens the
  /// active/preferred workspace), but after repeated no-progress reloads it
  /// escalates to a full rebuild — reloading over a wedged link is the
  /// reported "retry does nothing" path.
  Future<void> reloadTasks() async {
    final client = _client;
    if (client == null || _disposed) {
      await connect();
      return;
    }
    try {
      final bootstrap = await client.bootstrap();
      final list = bootstrap['workspaces'];
      _workspaces = [
        if (list is List)
          for (final w in list)
            if (w is Map) w.cast<String, dynamic>(),
      ];
      final tasks = bootstrap['tasks'];
      _relayTasks = [
        if (tasks is List)
          for (final t in tasks)
            if (t is Map) t.cast<String, dynamic>(),
      ];
    } catch (e) {
      _log('[session] reload bootstrap failed: $e');
      _softReloadFails += 1;
      if (_softReloadFails >= 2 &&
          _forceRebuildAfterStall('reload kept failing: $e')) {
        return;
      }
      _error = '$e';
      notifyListeners();
      return;
    }
    final target =
        _activeWorkspace ?? _preferredWorkspace ?? _workspaces.firstOrNull;
    if (target != null) {
      await openWorkspace(target);
    } else {
      // Nothing to open (no workspace on the desktop) — just repaint.
      notifyListeners();
    }
  }

  Future<void> stopTask(String sessionId) async {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    await conv.stop(sessionId);
  }

  Future<void> pauseTask(String sessionId) async {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    await conv.pauseGoal(sessionId);
  }

  Future<void> resumeTask(String sessionId) async {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    await conv.resumeGoal(sessionId);
  }

  /// Raw channel RPC over the active workspace bridge (usage-stats,
  /// model-provider, automations, off-peak...). Throws when no bridge is
  /// open.
  ///
  /// Both waits are bounded, and each timeout marks the link as stalled:
  /// the session forces one full suspend+connect rebuild so subsequent
  /// calls ride a fresh bridge instead of queueing on the wedged one.
  Future<dynamic> callChannel(
    String channel,
    String method, [
    List<Object?> args = const [],
  ]) async {
    final gate = _testGate ?? _liveGate();
    if (gate == null) throw StateError('not connected');
    try {
      await gate.waitHealthy(timeout: timings.healthyWaitTimeout);
    } on TimeoutException {
      _forceRebuildAfterStall(
        'workspace bridge unhealthy > ${timings.healthyWaitTimeout.inSeconds}s',
      );
      rethrow;
    }
    try {
      return await gate.call(channel, method, args).timeout(timings.rpcTimeout);
    } on TimeoutException {
      _forceRebuildAfterStall('$channel.$method timed out');
      rethrow;
    }
  }

  WorkspaceGate? _liveGate() {
    final bridge = _bridge;
    return bridge == null ? null : _LiveWorkspaceGate(bridge);
  }

  /// Test-only: route every channel RPC through [gate].
  @visibleForTesting
  void debugAttachGateForTest(WorkspaceGate gate) => _testGate = gate;

  /// Server-side automations of the connected desktop. Bound to the
  /// zcode-agent channel (listAllAutomations was probed there).
  @override
  late final AutomationPort automation = AutomationPort(
    (method, args) => callChannel('zcode-agent', method, args),
  );

  /// Off-peak tasks of the connected desktop (off-peak-task channel).
  @override
  late final OffPeakPort offPeak = OffPeakPort(
    (method, args) => callChannel('off-peak-task', method, args),
  );

  /// Official model-selection view (`model-selection` channel, getView):
  /// the provider/model list backing the off-peak form's model picker.
  /// Empty when the desktop rejects the call (older builds) — the form then
  /// falls back to prepareWorkspace options.
  @override
  Future<List<OffPeakModelChoice>> modelSelectionView() async {
    try {
      final res = await callChannel('model-selection', 'getView', []);
      return parseModelSelectionView(res);
    } catch (_) {
      return const [];
    }
  }

  /// Workspace scope (workspacePath/identity) for off-peak submissions and
  /// automation run-now triggers.
  @override
  Map<String, dynamic> get offPeakScope {
    final ws = _activeWorkspace ?? const <String, dynamic>{};
    return {
      'workspacePath': ws['workspacePath'],
      if (ws['workspaceIdentity'] != null)
        'workspaceIdentity': ws['workspaceIdentity'],
    };
  }

  @override
  Map<String, dynamic> get automationScope => offPeakScope;

  /// mobile-view-state-update for the ACTIVE workspace (web parity: the
  /// phone reports which workspace/task it is looking at; the desktop shows
  /// the「手机正在操作此任务」badge from it). Fire-and-forget; safe to call
  /// on every navigation.
  @override
  void sendViewState({String? taskId}) {
    final ws = _activeWorkspace;
    final client = _client;
    final key = ws == null ? null : workspaceKeyOf(ws);
    if (client == null || key == null) return;
    unawaited(client.sendMobileViewState(workspaceKey: key, taskId: taskId));
  }

  /// Minimal automation primitive: creates a new task (session) on the
  /// active workspace with [text] as the first message. Returns the new
  /// sessionId.
  Future<String> createTaskWithMessage(String text) async {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    final workspaceId = chatWorkspaceId;
    if (workspaceId == null || workspaceId.isEmpty) {
      throw StateError('no workspace');
    }
    return conv.createSession(workspaceId, firstText: text);
  }

  // ------------------------------------------------------------ ChatGateway

  ConversationTransport get _requireConversation {
    final conv = _conversation;
    if (conv == null) throw StateError('not connected');
    return conv;
  }

  @override
  String? get chatWorkspaceId {
    final fromIndex = sessions?.workspaceId;
    if (fromIndex != null && fromIndex.isNotEmpty) return fromIndex;
    final ws = _activeWorkspace;
    if (ws == null) return null;
    return '${ws['workspaceId'] ?? workspaceKeyOf(ws)}';
  }

  @override
  String? get workspacePath => _activeWorkspace?['workspacePath'] as String?;

  @override
  String? get remoteUrl => params.source.toString();

  /// Task metadata commands on the zcode-task channel (method names
  /// source-confirmed; probe kept as a safety net — see [TaskCommandsPort]).
  late final TaskCommandsPort taskCommands = TaskCommandsPort(
    (method, args) => callChannel('zcode-task', method, args),
    scope: () => offPeakScope,
  );

  @override
  Future<dynamic> renameTask(String sessionId, String title) =>
      taskCommands.rename(sessionId, title);

  @override
  Future<dynamic> setTaskPinned(String sessionId, bool pinned) =>
      taskCommands.setPinned(sessionId, pinned);

  @override
  Future<dynamic> setTaskArchived(String sessionId, bool archived) =>
      taskCommands.setArchived(sessionId, archived);

  @override
  Future<dynamic> setTaskUnread(String sessionId, bool unread) =>
      taskCommands.setUnread(sessionId, unread);

  @override
  Future<dynamic> deleteTask(String sessionId) =>
      taskCommands.delete(sessionId);

  /// Full reconnect after a KICK: drop everything and dial again.
  @override
  Future<void> reconnect() async {
    await suspend();
    await connect();
  }

  @override
  Future<ChatHandle> subscribe(String sessionId) async {
    final existing = _chatSubs[sessionId];
    if (existing != null) {
      return ChatHandle(
        state: existing.state,
        close: () async {
          if (_chatSubs[sessionId] == existing) {
            _chatSubs.remove(sessionId);
            await existing.dispose();
          }
        },
      );
    }
    final sub = await _requireConversation.subscribe(sessionId);
    _chatSubs[sessionId] = sub;
    return ChatHandle(
      state: sub.state,
      close: () async {
        if (_chatSubs[sessionId] == sub) {
          _chatSubs.remove(sessionId);
          await sub.dispose();
        }
      },
    );
  }

  @override
  Future<WorkspacePrep> prepareWorkspace() =>
      _requireConversation.prepareWorkspace();

  @override
  Future<List<SkillEntry>> skills() async {
    try {
      return await _requireConversation.skills();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String> createSession(
    String workspaceId, {
    String? firstText,
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic>? config,
  }) => _requireConversation.createSession(
    workspaceId,
    firstText: firstText,
    attachments: attachments,
    config: config,
  );

  @override
  Future<dynamic> sendText(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
  }) => _requireConversation.sendText(
    sessionId,
    text,
    attachments: attachments,
    heldQueueDisposition: heldQueueDisposition,
  );

  @override
  Future<dynamic> sendGoalCommand(
    String sessionId,
    String text, {
    String? heldQueueDisposition,
  }) => _requireConversation.sendGoalCommand(
    sessionId,
    text,
    heldQueueDisposition: heldQueueDisposition,
  );

  @override
  Future<dynamic> stop(String sessionId) =>
      _requireConversation.stop(sessionId);

  @override
  Future<dynamic> compact(String sessionId) =>
      _requireConversation.compact(sessionId);

  @override
  Future<dynamic> pauseGoal(String sessionId) =>
      _requireConversation.pauseGoal(sessionId);

  @override
  Future<dynamic> resumeGoal(String sessionId) =>
      _requireConversation.resumeGoal(sessionId);

  @override
  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) => _requireConversation.switchModelConfig(
    sessionId,
    provider: provider,
    model: model,
    thought: thought,
  );

  @override
  Future<dynamic> switchCollaborationMode(String sessionId, String mode) =>
      _requireConversation.switchCollaborationMode(sessionId, mode);

  @override
  Future<dynamic> setFollowupMode(String sessionId, String mode) =>
      _requireConversation.setFollowupMode(sessionId, mode);

  @override
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) => _requireConversation.setAssistantFeedback(sessionId, target, feedback);

  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) => _requireConversation.resolveInteraction(
    sessionId,
    interactionId,
    optionId: optionId,
    freeText: freeText,
    action: action,
    content: content,
  );

  @override
  Future<dynamic> respondWorkspaceHookReview(
    String sessionId,
    Map payload,
    List<String> reviewItemIds,
  ) => _requireConversation.respondWorkspaceHookReview(
    sessionId,
    payload,
    reviewItemIds,
  );

  @override
  Future<dynamic> resumeWorkflowRun(String sessionId, String runId,
          {String? name}) =>
      _requireConversation
          .resumeWorkflowRun(sessionId, runId, name: name);

  @override
  Future<List<Map<String, dynamic>>> runArtifacts(
      String sessionId, String runId) async {
    try {
      final res = await callChannel(
          'zcode-agent', 'conversationWorkflowRunArtifactsV4', [
        {'sessionId': sessionId, 'runId': runId},
      ]);
      if (res is Map && res['artifacts'] is List) {
        return [
          for (final a in res['artifacts'] as List)
            if (a is Map) a.cast<String, dynamic>(),
        ];
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> runArtifactData(
    String sessionId,
    String runId,
    String artifactId,
  ) async {
    try {
      final res = await callChannel(
          'zcode-agent', 'conversationWorkflowRunArtifactDataV4', [
        {'sessionId': sessionId, 'runId': runId, 'artifactId': artifactId},
      ]);
      if (res is Map && res['items'] is List) {
        return [
          for (final item in res['items'] as List)
            if (item is Map) item.cast<String, dynamic>(),
        ];
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<({Uint8List bytes, String? mediaType})?> runArtifactBytes(
    String sessionId,
    String runId,
    Map<String, dynamic> artifact,
  ) async {
    final artifactId = '${artifact['id'] ?? ''}';
    final version = '${artifact['version'] ?? ''}';
    if (artifactId.isEmpty || version.isEmpty) return null;
    try {
      final chunks = <int>[];
      String? mediaType;
      var offset = 0;
      for (var brake = 0; brake < 96; brake++) {
        final res = await callChannel(
            'zcode-agent', 'conversationWorkflowRunArtifactReadV4', [
          {
            'sessionId': sessionId,
            'runId': runId,
            'artifactId': artifactId,
            'version': version,
            'offset': offset,
            'limit': 524288,
          },
        ]);
        if (res is! Map) return null;
        mediaType ??= res['mediaType'] as String?;
        final data = res['dataBase64'] as String?;
        if (data != null && data.isNotEmpty) chunks.addAll(base64.decode(data));
        final next = (res['nextOffset'] as num?)?.toInt();
        if (next == null || next <= offset) break;
        offset = next;
      }
      return (bytes: Uint8List.fromList(chunks), mediaType: mediaType);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> usageEntitlement() async {
    try {
      final res = await callChannel(
        'usage-stats',
        'getEntitlementSnapshot',
        [
          {'includeSubscription': true},
        ],
      );
      return res is Map ? res.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) => _requireConversation.rowsRange(
    sessionId,
    beforeRowId: beforeRowId,
    limit: limit,
  );

  @override
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) => _requireConversation.attachmentPut(
    sessionId,
    fileName: fileName,
    mime: mime,
    bytes: bytes,
    onProgress: onProgress,
  );

  @override
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) => _requireConversation.attachmentRead(sessionId, ref: ref);

  @override
  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) =>
      _requireConversation.sendQueuedNow(sessionId, queueItemId);

  @override
  Future<dynamic> editQueueItem(
    String sessionId,
    String queueItemId,
    String newText,
  ) => _requireConversation.editQueueItem(sessionId, queueItemId, newText);

  @override
  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) =>
      _requireConversation.deleteQueueItem(sessionId, queueItemId);

  @override
  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) =>
      _requireConversation.setAutoDrain(sessionId, autoDrain);

  @override
  Future<dynamic> reorderQueueItem(
          String sessionId, String queueItemId, String? beforeQueueItemId) =>
      _requireConversation.reorderQueueItem(
          sessionId, queueItemId, beforeQueueItemId);

  @override
  Future<dynamic> snoozeInteraction(String sessionId, String interactionId) =>
      _requireConversation.snoozeInteractionAutoResolution(
          sessionId, interactionId);

  @override
  Future<dynamic> cancelBackgroundWork(String sessionId, String workId) =>
      _requireConversation.cancelBackgroundWork(sessionId, workId);

  @override
  Future<dynamic> deleteSession(String sessionId) =>
      _requireConversation.deleteSession(sessionId);

  @override
  Future<dynamic> plans(String sessionId) =>
      _requireConversation.plans(sessionId);

  @override
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  }) => _requireConversation.fileChanges(sessionId, target: target);

  @override
  Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target) =>
      _requireConversation.retryTurn(sessionId, target);

  @override
  Future<dynamic> forkAssistant(
    String sessionId,
    Map<String, dynamic> target,
  ) => _requireConversation.forkAssistant(sessionId, target);

  @override
  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText,
  ) => _requireConversation.editUserQuery(sessionId, target, newText);

  @override
  Future<dynamic> applyFileRewind(
    String sessionId,
    Map<String, dynamic> target,
  ) => _requireConversation.applyFileRewind(sessionId, target);

  @override
  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
  }) => _requireConversation.fileRewindPreview(sessionId, target: target);

  @override
  Future<List<Map<String, dynamic>>> mentionFiles() async {
    final root = workspacePath;
    if (root == null || root.isEmpty) return const [];
    try {
      final res = await callChannel('file', 'listWorkspaceFiles', [
        {'rootPath': root}
      ]);
      return res is List
          ? res.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
          : const [];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> mentionSkills() async {
    try {
      return [
        for (final s in await skills())
          {
            'id': s.name,
            'name': s.name,
            if (s.description != null) 'description': s.description,
          },
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> mentionSubagents() async {
    try {
      final res = await callChannel('subagents', 'list', []);
      final list = res is Map ? res['agents'] : res;
      return list is List
          ? list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
          : const [];
    } catch (_) {
      // Desktops without the subagent runtime reject the call — empty state.
      return const [];
    }
  }

  @override
  List<({String id, String title})> mentionSessions() {
    final list = sessions?.list ?? const [];
    return [
      for (final e in list) (id: e.sessionId, title: e.title),
    ];
  }

  @override
  List<Map<String, dynamic>> mentionSkillsSync() {
    return [
      for (final s in (conversation?.lastSkills ?? const <SkillEntry>[]))
        {
          'name': s.name,
          if (s.description != null) 'description': s.description,
        },
    ];
  }

  /// Cleanly closes the connection so the in-app WebView (or another
  /// terminal) can take the slot without a KICK race. Callers reconnect
  /// via [connect] later (the hub adds the ~1s grace delay).
  Future<void> suspend() async {
    if (_disposed) return;
    _retryTimer?.cancel();
    _listWatchdog?.cancel();
    _listEscalations = 0;
    _softReloadFails = 0;
    _connecting = false;
    _openingWorkspace = false;
    final client = _client;
    final bridge = _bridge;
    final sub = _sessionsSub;
    final chats = List.of(_chatSubs.values);
    _client = null;
    _bridge = null;
    _conversation = null;
    _sessionsSub = null;
    _chatSubs.clear();
    _activeWorkspace = null;
    _workspaces = [];
    _relayTasks = [];
    _failureReason = null;
    _kicked = false;
    _error = null;
    _setStatus(DeviceStatus.disconnected);
    await _failureSub?.cancel();
    _failureSub = null;
    await _wsListSub?.cancel();
    _wsListSub = null;
    await _appErrSub?.cancel();
    _appErrSub = null;
    unawaited(sub?.dispose());
    for (final s in chats) {
      unawaited(s.dispose());
    }
    bridge?.dispose();
    await client?.dispose();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await suspend();
    super.dispose();
  }

  void _log(String line) => debugPrint('[$deviceId] $line');
}

/// Owns one [DeviceSession] per device and mediates the
/// native-connection ↔ WebView handover. Kept as a plain ChangeNotifier so
/// device cards can rebuild on any session change.
class DeviceSessionHub extends ChangeNotifier {
  /// Whether the native task list feature is enabled (settings switch).
  final bool Function() nativeListEnabled;

  /// Grace period after the WebView closes before the native connection
  /// comes back — the relay needs a moment to free the device slot.
  static const resumeDelay = Duration(seconds: 1);

  final Map<String, DeviceSession> _sessions = {};
  final Map<String, Timer> _resumes = {};

  /// Last-opened workspace per device (survives WebView handovers).
  final Map<String, String> _lastWorkspaceKey = {};
  bool _disposed = false;

  DeviceSessionHub({required this.nativeListEnabled});

  DeviceSession? sessionOf(String deviceId) => _sessions[deviceId];

  /// All live native sessions (notification hub observes these).
  Iterable<DeviceSession> get activeSessions => _sessions.values;

  /// Test seam: place a pre-built session (FakeDeviceSession) into the hub
  /// with the same wiring [ensure] uses, without connecting anything.
  @visibleForTesting
  void installForTesting(DeviceSession session) {
    _sessions[session.deviceId] = session;
    session.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  /// Ensures [device] has a (re)connecting native session. Returns null
  /// for devices whose URL cannot be parsed (no protocol layer possible).
  DeviceSession? ensure(Device device) {
    if (_disposed || !nativeListEnabled()) return null;
    final existing = _sessions[device.id];
    if (existing != null) {
      if (existing.status == DeviceStatus.disconnected ||
          (existing.status == DeviceStatus.error && !existing.kicked)) {
        unawaited(existing.connect());
      }
      return existing;
    }
    final params = device.params;
    if (params == null) return null;
    final session = DeviceSession(
      deviceId: device.id,
      params: params,
      preferredWorkspaceKey: _lastWorkspaceKey[device.id],
      onWorkspaceOpened: (key) => _lastWorkspaceKey[device.id] = key,
    );
    _sessions[device.id] = session;
    session.addListener(_onSessionChanged);
    unawaited(session.connect());
    _onSessionChanged();
    return session;
  }

  /// Closes the native connection for the WebView handover. The pending
  /// resume timer (if any) is cancelled — the new one is armed by
  /// [scheduleResume] when the WebView page pops.
  Future<void> suspend(String deviceId) async {
    _resumes.remove(deviceId)?.cancel();
    final session = _sessions.remove(deviceId);
    if (session != null) {
      session.removeListener(_onSessionChanged);
      await session.suspend();
      _onSessionChanged();
    }
  }

  /// Reconnects [device] after [resumeDelay] (native list must be on).
  void scheduleResume(Device device) {
    if (_disposed || !nativeListEnabled()) return;
    final id = device.id;
    _resumes.remove(id)?.cancel();
    _resumes[id] = Timer(resumeDelay, () {
      _resumes.remove(id);
      if (_disposed) return;
      final current = _sessions[id];
      if (current == null) {
        ensure(device);
      } else if (current.status == DeviceStatus.disconnected) {
        unawaited(current.connect());
      }
    });
  }

  Future<void> disconnect(String deviceId) async {
    await suspend(deviceId);
  }

  /// Drops every native connection (native list disabled in settings).
  Future<void> disconnectAll() async {
    for (final id in _sessions.keys.toList()) {
      await disconnect(id);
    }
  }

  /// Reconciles native connections with the current device list and the
  /// native-list switch: connect new devices, drop removed ones, tear
  /// everything down when the feature is off.
  void syncWith(List<Device> devices) {
    if (_disposed) return;
    final ids = devices.map((d) => d.id).toSet();
    for (final id in _sessions.keys.toList()) {
      if (!ids.contains(id)) unawaited(disconnect(id));
    }
    if (nativeListEnabled()) {
      for (final d in devices) {
        ensure(d);
      }
    } else {
      unawaited(disconnectAll());
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final t in _resumes.values) {
      t.cancel();
    }
    _resumes.clear();
    final all = _sessions.values.toList();
    _sessions.clear();
    for (final s in all) {
      s.removeListener(_onSessionChanged);
      await s.dispose();
    }
    super.dispose();
  }

  void _onSessionChanged() {
    if (!_disposed) notifyListeners();
  }
}
