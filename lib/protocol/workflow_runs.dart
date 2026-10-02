/// Tolerant int read for workflow wire fields: the desktop has been seen
/// serializing ids/counts as numeric STRINGS (e.g. actors[].siteId = "0"),
/// so accept both num and numeric strings.
int? asWorkflowInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// Workflow run projection parsing (official `workflow-runs.ts`): the chat
/// card's live state folds entirely from `snapshot.workflowRuns.runs[]` —
/// no event polling needed (`timeline-model = buildWorkflowTimeline(graph,
/// run)` on the web side).

/// One workflow run as projected into the conversation snapshot.
class WorkflowRun {
  final Map<String, dynamic> raw;

  const WorkflowRun(this.raw);

  String get runId => '${raw['runId'] ?? ''}';
  String get toolCallId => '${raw['toolCallId'] ?? ''}';

  /// pending | running | completed | errored | stopped
  String get status => '${raw['status'] ?? ''}';

  bool get running => status == 'running';
  bool get live => status == 'running' || status == 'pending';

  /// user | model | provider | interrupted | superseded (only on stopped).
  String get stopReason => '${raw['stopReason'] ?? ''}';

  /// CLI-computed resumability bit — the UI never derives it itself.
  bool get resumable => raw['resumable'] == true;
  String get subagentModel => '${raw['subagentModel'] ?? ''}';
  String get currentPhase => '${raw['currentPhase'] ?? ''}'.trim();

  int get spentTokens =>
      _usageField('spentTokens') ?? 0;
  int get nodesUsed => _usageField('nodesUsed') ?? 0;
  int get lastEventSequence =>
      asWorkflowInt(raw['lastEventSequence']) ?? 0;

  int? _usageField(String key) {
    final usage = raw['usage'];
    return usage is Map ? asWorkflowInt(usage[key]) : null;
  }

  /// Declared phase names in launch order (the full track, including
  /// stations not yet reached).
  List<String> get phaseNames => [
        if (raw['phaseNames'] is List)
          for (final name in raw['phaseNames'] as List) '$name',
      ];

  /// Entered phases, first-entry order (`{name, rounds}`).
  List<String> get enteredPhaseNames => [
        if (raw['phases'] is List)
          for (final phase in raw['phases'] as List)
            if (phase is Map && phase['name'] != null) '${phase['name']}',
      ];

  /// True when the run has an entry record for [phaseName] (128-char prefix
  /// tolerance, web phaseNameMatches).
  bool enteredPhase(String phaseName) {
    for (final entered in enteredPhaseNames) {
      if (phaseNameMatches(entered, phaseName)) return true;
    }
    return false;
  }

  List<WorkflowRunActor> get actors => [
        if (raw['actors'] is List)
          for (final a in raw['actors'] as List)
            if (a is Map) WorkflowRunActor(a.cast<String, dynamic>()),
      ];

  List<WorkflowRunNode> get nodes => [
        if (raw['nodes'] is List)
          for (final n in raw['nodes'] as List)
            if (n is Map) WorkflowRunNode(n.cast<String, dynamic>()),
      ];

  /// User-facing artifact summaries (`{id, kind, title?, version, ...}`),
  /// first-publication order, latest version only.
  List<Map<String, dynamic>> get artifacts => [
        if (raw['artifacts'] is List)
          for (final a in raw['artifacts'] as List)
            if (a is Map) a.cast<String, dynamic>(),
      ];

  /// Outstanding escalations (`{qid?, actorSiteId?, actorOrdinal?,
  /// actorName?, question?, askedAt?}`).
  List<Map<String, dynamic>> get pendingQuestions => [
        if (raw['pendingQuestions'] is List)
          for (final q in raw['pendingQuestions'] as List)
            if (q is Map) q.cast<String, dynamic>(),
      ];

  /// Finds an actor by its instance key (`siteId@ordinal`).
  WorkflowRunActor? actor(int siteId, int ordinal) {
    for (final actor in actors) {
      if (actor.siteId == siteId && actor.ordinal == ordinal) return actor;
    }
    return null;
  }

  /// Official `phaseNameMatches` (128-char prefix tolerance both ways).
  static bool phaseNameMatches(String left, String right) {
    if (left == right) return true;
    final a = left.length > 128 ? left.substring(0, 128) : left;
    final b = right.length > 128 ? right.substring(0, 128) : right;
    return a == b;
  }
}

/// One subagent instance of a run (`actors[]` entries).
class WorkflowRunActor {
  final Map<String, dynamic> raw;

  const WorkflowRunActor(this.raw);

  int get siteId => asWorkflowInt(raw['siteId']) ?? 0;
  int get ordinal => asWorkflowInt(raw['ordinal']) ?? 0;
  String get name => '${raw['name'] ?? ''}';

  /// Deterministically minted actor session id; absent until the actor's
  /// session is recorded (self-heals on later snapshots).
  String get sessionId => '${raw['sessionId'] ?? ''}';

  /// waiting | running | completed
  String get status => '${raw['status'] ?? 'waiting'}';
  String get phaseName => '${raw['phaseName'] ?? ''}';

  String get instanceKey => '$siteId\x00$ordinal';
}

/// One script step instance of a run (`nodes[]` entries).
class WorkflowRunNode {
  final Map<String, dynamic> raw;

  const WorkflowRunNode(this.raw);

  int get siteId => asWorkflowInt(raw['siteId']) ?? 0;
  int get ordinal => asWorkflowInt(raw['ordinal']) ?? 0;

  /// queued | dispatched | executing | waiting | repairing | nudged |
  /// settled
  String get phase => '${raw['phase'] ?? 'queued'}';

  /// ok | failed | cancelled (set on settled).
  String get outcome => '${raw['outcome'] ?? ''}';
  int get actorSiteId => asWorkflowInt(raw['actorSiteId']) ?? 0;
  int get actorOrdinal => asWorkflowInt(raw['actorOrdinal']) ?? 0;
  String get phaseName => '${raw['phaseName'] ?? ''}';

  String get instanceKey => '$siteId\x00$ordinal';
  String get actorKey => '$actorSiteId\x00$actorOrdinal';
}

/// Four-value step status (web `StepRunStatus` / statusOfRunNode).
enum WorkflowStepStatus { pending, running, done, failed }

/// Official `statusOfRunNode` (run-status.ts:43): executing/repairing/nudged
/// read as running; settled resolves through outcome; everything earlier is
/// pending.
WorkflowStepStatus nodeStepStatus(WorkflowRunNode node) {
  switch (node.phase) {
    case 'executing':
    case 'repairing':
    case 'nudged':
      return WorkflowStepStatus.running;
    case 'settled':
      return node.outcome == 'failed' || node.outcome == 'cancelled'
          ? WorkflowStepStatus.failed
          : WorkflowStepStatus.done;
    default: // queued / dispatched / waiting
      return WorkflowStepStatus.pending;
  }
}

/// Official `aggregateRunStatuses` (run-status.ts:72): empty → null; any
/// running wins (deliberately over failed); queued+settled mixes into
/// running; all queued → pending; all settled → failed first, else done.
WorkflowStepStatus? aggregateStatuses(Iterable<WorkflowStepStatus> statuses) {
  final list = statuses.toList(growable: false);
  if (list.isEmpty) return null;
  var hasQueued = false;
  var hasSettled = false;
  for (final status in list) {
    if (status == WorkflowStepStatus.running) return WorkflowStepStatus.running;
    if (status == WorkflowStepStatus.pending) hasQueued = true;
    if (status == WorkflowStepStatus.done ||
        status == WorkflowStepStatus.failed) {
      hasSettled = true;
    }
  }
  if (hasQueued && hasSettled) return WorkflowStepStatus.running;
  if (hasQueued) return WorkflowStepStatus.pending;
  if (list.any((s) => s == WorkflowStepStatus.failed)) {
    return WorkflowStepStatus.failed;
  }
  return WorkflowStepStatus.done;
}

/// Convenience: aggregate a run's node statuses narrowed to one actor
/// instance (web participant-model narrowing: actor binding only — step
/// site narrowing stays on the caller, which owns the graph).
WorkflowStepStatus? actorStatus(
  WorkflowRun run,
  int siteId,
  int ordinal,
) {
  return aggregateStatuses([
    for (final node in run.nodes)
      if (node.actorSiteId == siteId && node.actorOrdinal == ordinal)
        nodeStepStatus(node),
  ]);
}

/// Per-phase entry counts for a run, keyed by phase name.
Map<String, int> phaseRounds(WorkflowRun run) {
  final rounds = <String, int>{};
  if (run.raw['phases'] is List) {
    for (final phase in run.raw['phases'] as List) {
      if (phase is Map && phase['name'] != null) {
        rounds['${phase['name']}'] = asWorkflowInt(phase['rounds']) ?? 0;
      }
    }
  }
  return rounds;
}

/// March-ink target for the timeline: the edge entering the running station
/// lights up (web timeline-model march rules, lite). Returns the station
/// index the light flows TOWARD, or null when nothing is running.
int? marchTarget({
  required List<String> track,
  required String currentPhase,
  required bool runLive,
}) {
  if (!runLive || currentPhase.isEmpty) return null;
  for (var i = 0; i < track.length; i++) {
    if (WorkflowRun.phaseNameMatches(track[i], currentPhase)) return i;
  }
  return null;
}

