import 'channel_client.dart';
import 'id.dart';
import 'method_probe.dart';

/// Off-peak tasks (闲时任务): free runs in compute-rich windows, submitted
/// into a server-side queue. Coding Plan subscription required with a
/// monthly quota.
///
/// Wire messages (zod-style, from the off-peak protocol family; verified
/// against the live desktop where noted):
/// ```text
/// off-peak-run = {                  // submit a queued run
///   offPeakTaskId: string,
///   workspacePath: string,
///   workspaceIdentity?: string,
///   prompt: string,
///   permissionMode: string,         // e.g. 'build' | 'plan' | 'yolo'
///   model?: string, thoughtLevel?: string,
///   conversationId?: string,        // resume/续投 carries these
///   sessionId?: string,
///   serverTicketId?: string,
/// }
/// off-peak-run-result = {           // pushed/returned when a run finishes
///   ok: boolean,
///   conversationId?: string, sessionId?: string,
///   error?: 'codingPlanOnly' | 'quota' | 'unavailable' | string,
/// }
/// off-peak-scheduler-wake-request = {}  // nudge the scheduler to re-check
/// ```
/// `sendText` accepts `offPeakTaskId` + `offPeakRunType: 'init'|'resume'`
/// for 续投 (already implemented in conversation.dart's sendText).
///
/// Channel: `off-peak-task` (present in the desktop channel registry;
/// confirmed via the zemote channel explorer). Method names below are
/// NOT yet live-confirmed — each op probes candidates via [MethodProbe]
/// and remembers the winner; validation/permission errors surface as-is.
class OffPeakPort {
  final Future<dynamic> Function(String method, List<Object?> args) call;

  OffPeakPort(this.call) : _probe = MethodProbe(call);

  final MethodProbe _probe;

  static const _listMethods = [
    'list',
    'listAll',
    'listOffPeakTasks',
    'listTasks',
  ];
  // createTask/updateTask/pauseTask/continueTask/cancelTask/deleteTask/
  // deleteHistory are the desktop service's own names (seen in the desktop
  // UI chunk's offPeak store); the others keep first-shot precedence from
  // earlier probing rounds.
  static const _submitMethods = [
    'run',
    'submit',
    'createTask',
    'submitOffPeakTask',
    'createOffPeakTask',
  ];
  static const _pauseMethods = ['pause', 'pauseTask', 'pauseOffPeakTask'];
  static const _resumeMethods = [
    'resume',
    'continueTask',
    'resumeOffPeakTask',
  ];
  static const _cancelMethods = ['cancel', 'cancelTask', 'cancelOffPeakTask'];
  static const _deleteMethods = ['delete', 'deleteTask', 'deleteOffPeakTask'];
  static const _historyDeleteMethods = [
    'deleteHistory',
    'delete',
    'deleteTask',
  ];
  static const _updateMethods = [
    'updateTask',
    'editOffPeakTask',
    'updateOffPeakTask',
    'update',
  ];
  static const _statusMethods = ['getStatus', 'getQuota', 'status'];
  static const _wakeMethods = [
    'wake',
    'wakeScheduler',
    'off-peak-scheduler-wake-request',
  ];

  // ------------------------------------------------------------------ list

  /// Lists off-peak tasks (active queue + history).
  Future<List<OffPeakTask>> list() async {
    final res = await _probe.run('list', _listMethods);
    dynamic items = res;
    if (res is Map) {
      items = res['tasks'] ?? res['items'] ?? res['list'] ?? res['history'];
    }
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map) OffPeakTask(item.cast<String, dynamic>()),
    ];
  }

  // ---------------------------------------------------------------- submit

  /// Submits a queued run. Returns the ack (run-result-shaped when the
  /// server answers inline). Throws [OffPeakError] with a classified kind
  /// for codingPlanOnly / quota / unavailable failures.
  Future<OffPeakRunResult> submit(OffPeakSubmitInput input) async {
    dynamic res;
    try {
      res = await _probe.run('submit', _submitMethods,
          argsOf: (_) => [input.toWire()]);
    } on ChannelRpcError catch (e) {
      throw OffPeakError.fromMessage(e.message, e);
    }
    final ack =
        res is Map ? res.cast<String, dynamic>() : const <String, dynamic>{};
    return OffPeakRunResult.from(ack, echo: input.toWire());
  }

  // ------------------------------------------------------------ lifecycle

  Future<void> pause(String taskId) => _lifecycle('pause', _pauseMethods,
      {'offPeakTaskId': taskId});

  Future<void> resume(String taskId) => _lifecycle('resume', _resumeMethods,
      {'offPeakTaskId': taskId});

  Future<void> cancel(String taskId) => _lifecycle('cancel', _cancelMethods,
      {'offPeakTaskId': taskId});

  /// History removal (desktop separates 删除历史记录 from task delete).
  /// Falls back to the plain delete candidates on older desktops.
  Future<void> remove(String taskId) => _lifecycle('delete', _deleteMethods,
      {'offPeakTaskId': taskId});

  Future<void> deleteHistory(String taskId) =>
      _lifecycle('history-delete', _historyDeleteMethods,
          {'offPeakTaskId': taskId});

  // ---------------------------------------------------------------- update

  /// Edits an existing queued/paused run. The desktop update call passes
  /// `{title, prompt, permissionMode, model, thoughtLevel}` keyed by the
  /// task id; `model`/`thoughtLevel` arrive as explicit nulls when unset.
  /// Arg shapes: 0 = `[{offPeakTaskId, ...patch}]`,
  /// 1 = `[taskId, {patch}]` — resolved once and remembered.
  Future<void> update(String taskId, OffPeakUpdateInput patch) async {
    const shapes = 2;
    Object? firstError;
    for (var shape = 0; shape < shapes; shape++) {
      final args = switch (shape) {
        0 => <Object?>[{'offPeakTaskId': taskId, ...patch.toWire()}],
        _ => <Object?>[taskId, patch.toWire()],
      };
      try {
        await _probe.run('update:$shape', _updateMethods,
            argsOf: (_) => args);
        return;
      } on ChannelRpcError catch (e) {
        if (!MethodProbe.missingMethod(e.message)) rethrow;
        firstError ??= e;
      }
    }
    throw firstError ?? StateError('update: no candidate methods left');
  }

  Future<void> _lifecycle(String op, List<String> methods, Map arg) async {
    try {
      await _probe.run(op, methods, argsOf: (_) => [arg]);
    } on ChannelRpcError catch (e) {
      throw OffPeakError.fromMessage(e.message, e);
    }
  }

  // ---------------------------------------------------------------- status

  /// Entitlement + quota status (订阅门槛、月度额度、最早可用时间).
  /// Returns null when every status method is rejected (older desktop) —
  /// the UI then omits the quota header instead of failing.
  Future<OffPeakStatus?> status() async {
    dynamic res;
    try {
      res = await _probe.run('status', _statusMethods);
    } on ChannelRpcError {
      return null;
    }
    if (res is! Map) return null;
    return OffPeakStatus(res.cast<String, dynamic>());
  }

  /// Nudges the desktop scheduler (`off-peak-scheduler-wake-request`
  /// family). Best-effort; failures are ignored by callers.
  Future<void> wake() async {
    try {
      await _probe.run('wake', _wakeMethods);
    } catch (_) {
      // Wake is an optimization, never an error surface.
    }
  }
}

/// Structured model choice (official `modelSelectionSchema`): the desktop
/// createTask/updateTask contract — tasks without it "不能进入调度" and can
/// only ever run the default model. [reasoningLevel] rides `options`.
class OffPeakModelSelection {
  final String providerId;
  final String modelId;
  final String? reasoningLevel;

  const OffPeakModelSelection({
    required this.providerId,
    required this.modelId,
    this.reasoningLevel,
  });

  /// `providerId/modelId` (picker display/legacy `model` field shape).
  String get composite => '$providerId/$modelId';

  Map<String, dynamic> toWire() => {
        'providerId': providerId,
        'modelId': modelId,
        if (reasoningLevel != null && reasoningLevel!.isNotEmpty)
          'options': {'reasoningLevel': reasoningLevel},
      };

  /// Tolerant parse of a task's stored `modelSelection` map.
  static OffPeakModelSelection? from(Map? raw) {
    if (raw == null) return null;
    final providerId = '${raw['providerId'] ?? ''}'.trim();
    final modelId = '${raw['modelId'] ?? ''}'.trim();
    if (providerId.isEmpty || modelId.isEmpty) return null;
    final options = raw['options'];
    final level = options is Map ? '${options['reasoningLevel'] ?? ''}' : '';
    return OffPeakModelSelection(
      providerId: providerId,
      modelId: modelId,
      reasoningLevel: level.isEmpty ? null : level,
    );
  }
}

/// One pickable model parsed from the official `model-selection`
/// getView payload (`providers[].models[]`, reasoning levels from
/// `config.optionSpecs.reasoningLevel` — web resolveModelThoughtOption).
class OffPeakModelChoice {
  final String providerId;
  final String modelId;
  final String providerName;

  /// Registry display name when present, else the bare modelId.
  final String name;
  final List<String> reasoningLevels;

  const OffPeakModelChoice({
    required this.providerId,
    required this.modelId,
    this.providerName = '',
    this.name = '',
    this.reasoningLevels = const [],
  });

  String get composite => '$providerId/$modelId';

  OffPeakModelSelection selection({String? reasoningLevel}) =>
      OffPeakModelSelection(
        providerId: providerId,
        modelId: modelId,
        reasoningLevel: reasoningLevel,
      );
}

/// Flattens the official ModelSelectionView into pickable choices (provider
/// order preserved; one entry per model). Returns empty when the desktop
/// rejected the call or the payload shape changed.
List<OffPeakModelChoice> parseModelSelectionView(Object? view) {
  if (view is! Map) return const [];
  final providers = view['providers'];
  if (providers is! List) return const [];
  final choices = <OffPeakModelChoice>[];
  for (final provider in providers) {
    if (provider is! Map) continue;
    final providerId = '${provider['providerId'] ?? ''}'.trim();
    if (providerId.isEmpty) continue;
    final providerName = '${provider['providerName'] ?? providerId}';
    final models = provider['models'];
    if (models is! List) continue;
    for (final model in models) {
      if (model is! Map) continue;
      final modelId = '${model['modelId'] ?? ''}'.trim();
      if (modelId.isEmpty) continue;
      String name = modelId;
      final config = model['config'];
      if (config is Map) {
        for (final key in const ['displayName', 'name', 'label']) {
          final v = config[key];
          if (v is String && v.trim().isNotEmpty) {
            name = v.trim();
            break;
          }
        }
      }
      final levels = <String>[];
      if (config is Map) {
        final specs = config['optionSpecs'];
        final reasoning = specs is Map ? specs['reasoningLevel'] : null;
        final values = reasoning is Map ? reasoning['values'] : null;
        if (values is List) {
          levels.addAll([for (final v in values) '$v']);
        }
      }
      choices.add(OffPeakModelChoice(
        providerId: providerId,
        modelId: modelId,
        providerName: providerName,
        name: name,
        reasoningLevels: levels,
      ));
    }
  }
  return choices;
}

/// Submit form → wire (`off-peak-run`). Exactly the documented fields;
/// [earliestAtMs]/[title] ride along as display hints (beyond the
/// documented schema, ignored by desktops that don't know them).
///
/// [modelSelection] is the official createTask contract (structured
/// provider/model/reasoning); legacy `model`/`thoughtLevel` are dual-written
/// so older desktops keep working.
class OffPeakSubmitInput {
  final String prompt;
  final String workspacePath;
  final String? workspaceIdentity;
  final String permissionMode;
  final String? model;
  final String? thoughtLevel;
  final OffPeakModelSelection? modelSelection;
  final int? earliestAtMs;
  final String? title;

  /// Client-chosen task id (server may also assign one). Defaults to a
  /// fresh uuid when omitted.
  final String? offPeakTaskId;

  OffPeakSubmitInput({
    required this.prompt,
    required this.workspacePath,
    this.workspaceIdentity,
    this.permissionMode = 'build',
    this.model,
    this.thoughtLevel,
    this.modelSelection,
    this.earliestAtMs,
    this.title,
    String? offPeakTaskId,
  }) : offPeakTaskId = offPeakTaskId ?? generateUuid();

  Map<String, dynamic> toWire() => {
        'offPeakTaskId': offPeakTaskId,
        'workspacePath': workspacePath,
        if (workspaceIdentity != null && workspaceIdentity!.isNotEmpty)
          'workspaceIdentity': workspaceIdentity,
        'prompt': prompt.trim(),
        'permissionMode': permissionMode,
        if (model != null && model!.isNotEmpty) 'model': model,
        if (thoughtLevel != null && thoughtLevel!.isNotEmpty)
          'thoughtLevel': thoughtLevel,
        if (modelSelection != null) 'modelSelection': modelSelection!.toWire(),
        if (earliestAtMs != null) 'earliestAvailableAt': earliestAtMs,
        if (title != null && title!.isNotEmpty) 'title': title,
      };}

/// Edit-form patch for an existing run (desktop `updateTask` shape).
/// [model]/[thoughtLevel] are emitted explicitly (null included) — the
/// desktop sends `?? null` for them, and they clear overrides when null.
/// [modelSelection] rides along when the form has a structured choice
/// (official updateTask contract; null there means "unchanged").
class OffPeakUpdateInput {
  final String title;
  final String prompt;
  final String permissionMode;

  /// Plain model name (allowedModels entries); null = 默认模型.
  final String? model;

  /// Thought level (allowedModelConfigs reasoning levels); null = 默认.
  final String? thoughtLevel;

  /// Structured selection (official `modelSelection`); emitted only when
  /// the form resolved one.
  final OffPeakModelSelection? modelSelection;

  const OffPeakUpdateInput({
    required this.title,
    required this.prompt,
    this.permissionMode = 'build',
    this.model,
    this.thoughtLevel,
    this.modelSelection,
  });

  Map<String, dynamic> toWire() => {
        'title': title.trim(),
        'prompt': prompt.trim(),
        'permissionMode': permissionMode,
        'model': (model == null || model!.isEmpty) ? null : model,
        'thoughtLevel':
            (thoughtLevel == null || thoughtLevel!.isEmpty) ? null : thoughtLevel,
        if (modelSelection != null) 'modelSelection': modelSelection!.toWire(),
      };
}

/// Parsed `off-peak-run-result`.
class OffPeakRunResult {
  final bool ok;
  final String? conversationId;
  final String? sessionId;
  final String? error;
  final Map<String, dynamic> raw;

  const OffPeakRunResult({
    required this.ok,
    this.conversationId,
    this.sessionId,
    this.error,
    this.raw = const {},
  });

  factory OffPeakRunResult.from(Map<String, dynamic> raw,
      {Map<String, dynamic>? echo}) {
    final error = raw['error'] as String?;
    return OffPeakRunResult(
      // A void ack (no ok, no error) means accepted.
      ok: raw['ok'] != false && error == null,
      conversationId: raw['conversationId'] as String? ??
          echo?['conversationId'] as String?,
      sessionId:
          raw['sessionId'] as String? ?? echo?['sessionId'] as String?,
      error: error,
      raw: raw,
    );
  }
}

/// Read-side view of one off-peak task. Field names tolerate the common
/// id/status spellings seen across protocol versions.
class OffPeakTask {
  final Map<String, dynamic> raw;
  OffPeakTask(this.raw);

  String get id =>
      '${raw['offPeakTaskId'] ?? raw['taskId'] ?? raw['id'] ?? ''}';

  String get title => '${raw['title'] ?? ''}';
  String get prompt => '${raw['prompt'] ?? raw['instruction'] ?? ''}';

  /// queued | running | paused | completed | failed | cancelled
  /// (tolerant: also 'waitingQueue'/'waiting'/'pending', 'succeeded',
  /// 'error').
  String get status => _norm('${raw['status'] ?? raw['state'] ?? ''}');

  static String _norm(String s) => switch (s.toLowerCase()) {
        'succeeded' => 'completed',
        'error' => 'failed',
        'waiting' || 'pending' || 'waitingqueue' || 'queued' => 'queued',
        _ => s.toLowerCase(),
      };

  bool get queued => status == 'queued';
  bool get running => status == 'running';
  bool get paused => status == 'paused';
  bool get completed => status == 'completed';
  bool get failed => status == 'failed';
  bool get terminal => completed || failed || status == 'cancelled';

  /// Server-provided queue position (排队位置); null when not reported.
  int? get queuePosition => (raw['queuePosition'] as num?)?.toInt();

  String? get permissionMode => raw['permissionMode'] as String?;

  int? get createdAt => (raw['createdAt'] as num?)?.toInt();
  int? get startedAt => (raw['startedAt'] as num?)?.toInt();
  int? get finishedAt => (raw['finishedAt'] as num?)?.toInt();

  /// Run duration when known (finishedAt - startedAt).
  int? get durationMs {
    final start = startedAt;
    final end = finishedAt;
    if (start == null || end == null || end <= start) return null;
    return end - start;
  }

  String? get sessionId => raw['sessionId'] as String?;
  String? get conversationId => raw['conversationId'] as String?;
  String? get error => raw['error'] as String?;
  String? get model => raw['model'] as String?;

  /// Structured selection stored by the desktop (createTask/updateTask
  /// contract); null on legacy records that only carry model/thoughtLevel.
  OffPeakModelSelection? get modelSelection =>
      OffPeakModelSelection.from(raw['modelSelection'] is Map
          ? raw['modelSelection'] as Map
          : null);
}

/// Entitlement + quota snapshot for the page header.
class OffPeakStatus {
  final Map<String, dynamic> raw;
  OffPeakStatus(this.raw);

  /// codingPlanOnly / quota / unavailable / null (entitled).
  String? get reason {
    final r = raw['reason'] ?? raw['unavailableReason'];
    return r is String ? OffPeakError.normalize(r) : null;
  }

  bool get entitled => reason == null && raw['available'] != false;

  /// Monthly quota remaining, minutes (display: 小时/分钟).
  int? get quotaRemainingMinutes =>
      (raw['quotaRemainingMinutes'] as num?)?.toInt() ??
      (raw['remainingMinutes'] as num?)?.toInt();

  int? get quotaTotalMinutes =>
      (raw['quotaTotalMinutes'] as num?)?.toInt() ??
      (raw['totalMinutes'] as num?)?.toInt();

  /// When idle capacity is next expected (最早可用).
  int? get earliestAvailableAt =>
      (raw['earliestAvailableAt'] as num?)?.toInt() ??
      (raw['nextWindowAt'] as num?)?.toInt();

  /// When the exhausted quota resets, epoch ms (额度耗尽后的剩余等待).
  /// Tolerant: absolute-epoch fields at ms/s scale or an explicit remaining
  /// duration in ms/seconds.
  int? quotaResetRemainingMs(int nowMs) {
    final reset =
        (raw['quotaResetAt'] as num?)?.toInt() ??
            (raw['limitReachedResetAt'] as num?)?.toInt();
    if (reset != null) {
      final ms = reset < 100000000000 ? reset * 1000 : reset;
      return ms - nowMs;
    }
    final remMs = (raw['quotaResetRemainingMs'] as num?)?.toInt() ??
        (raw['remainingWaitSeconds'] as num?)?.toInt();
    if (remMs == null) return null;
    // Heuristic: seconds-based waits never reach an hour of magnitude.
    return remMs > 1000000 ? remMs : remMs * 1000;
  }
}

/// Classified off-peak failure (门槛/额度/服务不可用), used to pick the
/// exact official error copy in the UI.
class OffPeakError implements Exception {
  /// OffPeakError.codingPlanOnly / .quota / .unavailable / .other
  final String kind;
  final String message;
  final Object? cause;

  const OffPeakError(this.kind, this.message, [this.cause]);

  static const codingPlanOnly = 'codingPlanOnly';
  static const quota = 'quota';
  static const unavailable = 'unavailable';
  static const other = 'other';

  /// Maps a raw RPC failure message onto the official error states.
  /// Feature-absent desktops (every candidate method rejected) count as
  /// 服务暂不可用.
  static String normalize(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('codingplan') ||
        m.contains('coding plan') ||
        m.contains('subscription') ||
        m.contains('订阅')) {
      return codingPlanOnly;
    }
    if (m.contains('quota') ||
        m.contains('额度') ||
        m.contains('limit') ||
        m.contains('exceeded')) {
      return quota;
    }
    if (m.contains('unavailable') ||
        m.contains('不可用') ||
        m.contains('no such method') ||
        m.contains('unknown method') ||
        m.contains('method not found') ||
        m.contains('unsupported')) {
      return unavailable;
    }
    return other;
  }

  factory OffPeakError.fromMessage(String message, [Object? cause]) =>
      OffPeakError(normalize(message), message, cause);

  @override
  String toString() => 'OffPeakError($kind): $message';
}
