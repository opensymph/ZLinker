import 'dart:async';

import 'package:flutter/material.dart';

import '../../protocol/conversation.dart';
import '../../protocol/workflow_runs.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'goal_panel.dart';

/// Conversation-level panels above the composer: goal banner + process
/// panel, workflow/bash status rows, queue bar, quota banner and draft
/// prompt suggestions. Split out of chat_page.dart for size.

class QuotaBanner extends StatefulWidget {
  final ChatGateway gateway;

  const QuotaBanner({super.key, required this.gateway});

  @override
  State<QuotaBanner> createState() => _QuotaBannerState();
}

class _QuotaBannerState extends State<QuotaBanner> {
  Map<String, dynamic>? _entitlement;
  bool _loaded = false;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entitlement = await widget.gateway.usageEntitlement();
    if (!mounted) return;
    setState(() {
      _entitlement = entitlement;
      _loaded = true;
    });
  }

  /// (kind, percent remaining, next reset) or null when healthy/absent.
  ({String kind, int? percent, String? resetAt})? _bannerState() {
    final entitlement = _entitlement;
    if (entitlement == null) return null;
    final quota = entitlement['quota'];
    final limits = quota is Map ? quota['limits'] : null;
    if (limits is! List) return null;
    String? kind;
    int? worstPercent;
    String? resetAt;
    for (final bucket in limits) {
      if (bucket is! Map) continue;
      if ('${bucket['meter'] ?? 'model_usage'}' != 'model_usage') continue;
      final number = (bucket['number'] as num?)?.toDouble() ?? 0;
      if (number <= 0) continue;
      final remaining = (bucket['remaining'] as num?)?.toDouble() ??
          number - ((bucket['usage'] as num?)?.toDouble() ?? 0);
      var ratio = remaining / number;
      if (ratio < 0 && (bucket['percentage'] as num?) != null) {
        ratio = 1 - (bucket['percentage'] as num).toDouble();
      }
      ratio = ratio.clamp(0.0, 1.0);
      final daily = '${bucket['period'] ?? ''}' == 'daily';
      final percent = (ratio * 100).round();
      if (ratio <= 0) {
        final bucketKind = daily ? 'dailyExhausted' : 'modelExhausted';
        if (kind == null ||
            kind == 'modelVeryLow' ||
            (kind == 'modelExhausted' && bucketKind == 'dailyExhausted')) {
          kind = bucketKind;
          worstPercent = 0;
        }
      } else if (ratio < 0.1) {
        if (kind == null || kind == 'modelVeryLow') {
          kind = 'modelVeryLow';
          worstPercent = percent;
        }
      }
      final next = bucket['nextResetTime'];
      if (next is num && resetAt == null) {
        final t = DateTime.fromMillisecondsSinceEpoch(next.toInt()).toLocal();
        String two(int v) => v.toString().padLeft(2, '0');
        resetAt =
            '${two(t.month)}/${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
      }
    }
    if (kind == null) return null;
    return (kind: kind, percent: worstPercent, resetAt: resetAt);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _dismissed) return const SizedBox.shrink();
    final banner = _bannerState();
    if (banner == null) return const SizedBox.shrink();
    final text = switch (banner.kind) {
      'dailyExhausted' => tr(context, 'chat.quota.dailyExhausted'),
      'modelExhausted' => tr(context, 'chat.quota.modelExhausted'),
      _ => trP(context, 'chat.quota.modelVeryLow', ['${banner.percent ?? 0}']),
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ZColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.battery_alert_outlined, size: 15, color: ZColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              banner.resetAt == null
                  ? text
                  : '$text · ${trP(context, 'chat.quota.resetAt', [
                          banner.resetAt!
                        ])}',
              style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _dismissed = true),
            child: Icon(Icons.close, size: 14, color: ZInk.muted(context)),
          ),
        ],
      ),
    );
  }
}

/// Draft-mode prompt suggestions (web draftSuggestedPromptItems parity, with
/// a static local list — the official list is cloud-REST-delivered and the
/// pairing link has no cloud credentials).
class DraftSuggestedPrompts extends StatelessWidget {
  final ValueChanged<String> onPick;

  const DraftSuggestedPrompts({super.key, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final prompts = [
      tr(context, 'chat.suggest.1'),
      tr(context, 'chat.suggest.2'),
      tr(context, 'chat.suggest.3'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final prompt in prompts)
            ActionChip(
              label: Text(
                prompt,
                style: TextStyle(
                  fontSize: 12,
                  color: ZInk.soft(context),
                ),
              ),
              side: BorderSide(color: ZInk.hairline(context)),
              backgroundColor: ZInk.tile(context),
              onPressed: () => onPick(prompt),
            ),
        ],
      ),
    );
  }
}

class GoalBanner extends StatelessWidget {
  final ConversationState state;

  const GoalBanner({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final goal = state.goal;
    if (goal == null) return const SizedBox.shrink();
    final objective = '${goal['objective'] ?? ''}';
    if (objective.isEmpty) return const SizedBox.shrink();
    final status = '${goal['status'] ?? ''}';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ZColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.success.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.flag_outlined, size: 14, color: ZColors.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              objective,
              style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (status.isNotEmpty)
            Text(
              status,
              style: const TextStyle(fontSize: 11, color: ZColors.success),
            ),
        ],
      ),
    );
  }
}

/// Bridges the conversation snapshot's goal/subagent data to the
/// web 目标面板 parity widget (hidden when no goal is set — the plain
/// GoalBanner covers that case).
class GoalProcessPanel extends StatelessWidget {
  final ConversationState state;
  final ChatGateway gateway;

  const GoalProcessPanel(
      {super.key, required this.state, required this.gateway});

  @override
  Widget build(BuildContext context) {
    if (state.snapshot?['goal'] is! Map) return const SizedBox.shrink();
    return GoalPanel(
      state: state,
      onPauseGoal: (sid) => gateway.pauseGoal(sid),
      onResumeGoal: (sid) => gateway.resumeGoal(sid),
    );
  }
}

/// Web statusPanel parity for the conversation-level sections the snapshot
/// carries: git environment (probed — the official client sources it from a
/// workspace-level channel, so the row only renders when the field shows
/// up), running workflow runs (workflowRuns.runs joined with backgroundWorks
/// kind=workflow by workId ≡ runId) and running bash works.
class StatusPanel extends StatefulWidget {
  final ConversationState state;
  final ChatGateway gateway;

  const StatusPanel({super.key, required this.state, required this.gateway});

  @override
  State<StatusPanel> createState() => _StatusPanelState();
}

/// Official StatusSection parity: the workflow/terminal sections are
/// COLLAPSED by default (web defaultOpen=false) — collapsed they show only
/// a header line (title + longest elapsed · N background runs), so an
/// unnamed run no longer paints a permanent card under the conversation.
class _StatusPanelState extends State<StatusPanel> {
  final Set<String> _openSections = {};

  /// Official narrow-viewport behavior: the panel starts as the compact
  /// StatusSummaryRow capsule (top, right-aligned); tapping it expands the
  /// full sections card.
  bool _expanded = false;

  ConversationState get state => widget.state;
  ChatGateway get gateway => widget.gateway;

  /// Git data is NOT part of the official conversation snapshot (it comes
  /// from a workspace-level channel); probe the plausible keys so a future
  /// relay that surfaces it lights the row up for free.
  Map? _probeGit() {
    final snapshot = state.snapshot;
    if (snapshot == null) return null;
    for (final key in const ['git', 'gitSummary', 'gitRepository']) {
      final v = snapshot[key];
      if (v is Map && '${v['branchName'] ?? v['branch'] ?? ''}'.isNotEmpty) {
        return v.cast<String, dynamic>();
      }
    }
    return null;
  }

  /// Workflow rows: runs first (they carry status/steps), then any running
  /// kind=workflow work without a matching run (degraded rows). Ended works
  /// must not render — they would otherwise stick around as spinner rows.
  List<Map> _workflowRows() {
    final workflowRuns = state.snapshot?['workflowRuns'];
    final runsRaw = workflowRuns is Map ? workflowRuns['runs'] : null;
    final runs =
        runsRaw is List ? runsRaw.whereType<Map>().toList() : const <Map>[];
    final works = state.backgroundWorks
        .where((w) =>
            w['kind'] == 'workflow' &&
            w['status'] == 'running' &&
            w['endedAt'] == null)
        .toList();
    final rows = <Map>[];
    final seenWorkIds = <String>{};
    for (final run in runs) {
      final workId = '${run['workId'] ?? run['runId'] ?? ''}';
      seenWorkIds.add(workId);
      rows.add(run.cast<String, dynamic>());
    }
    for (final work in works) {
      final workId = '${work['workId'] ?? ''}';
      if (seenWorkIds.contains(workId)) continue;
      rows.add({
        'runId': workId,
        'workId': workId,
        'title': work['title'],
        'cancellable': work['cancellable'],
      });
    }
    return rows;
  }

  /// Longest elapsed among started rows, formatted like the row tickers
  /// (web trailing shows it on the collapsed header).
  String? _longestElapsed(List<Map> rows) {
    final now = DateTime.now().millisecondsSinceEpoch;
    int? longest;
    for (final row in rows) {
      final startedAt = (row['startedAt'] as num?)?.toInt();
      if (startedAt == null) continue;
      final elapsed = (now - startedAt).clamp(0, 1 << 31);
      if (longest == null || elapsed > longest) longest = elapsed;
    }
    if (longest == null) return null;
    final totalSeconds = longest >= 1000 ? longest ~/ 1000 : 1;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    if (minutes > 0) {
      return trP(context, 'goalPanel.runningFor',
          ['$minutes', seconds.toString().padLeft(2, '0')]);
    }
    return trP(context, 'goalPanel.duration.s', ['$seconds']);
  }

  Widget _sectionHeader({
    required String key,
    required String title,
    required int count,
    String? elapsed,
  }) {
    final open = _openSections.contains(key);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() {
        if (!open) {
          _openSections.add(key);
        } else {
          _openSections.remove(key);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Text(title,
                style: TextStyle(fontSize: 12.5, color: ZInk.muted(context))),
            const SizedBox(width: 4),
            Icon(
              open ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
              size: 14,
              color: ZInk.faint(context),
            ),
            const Spacer(),
            if (!open) ...[
              if (elapsed != null)
                Text(elapsed,
                    style:
                        TextStyle(fontSize: 11, color: ZInk.faint(context))),
              if (elapsed != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text('·',
                      style: TextStyle(
                          fontSize: 11, color: ZInk.faint(context))),
                ),
            ],
            Text(
              trP(context, 'chat.status.section.runningCount', ['$count']),
              style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
            ),
          ],
        ),
      ),
    );
  }

  int _runningSubagentCount() {
    final subagents = state.snapshot?['subagents'];
    final running = subagents is Map ? subagents['running'] : null;
    return running is List ? running.length : 0;
  }

  /// Official StatusSummaryRow fallback chain (git-diff branch skipped —
  /// the mobile relay has no workspace git summary).
  Widget? _capsuleMetric(BuildContext context) {
    final workflows = _workflowRows();
    final bashes = state.backgroundWorks
        .where((w) => w['kind'] == 'bash' && w['status'] == 'running')
        .toList();
    final planRaw = state.plan;
    final Map<String, dynamic> planMap =
        planRaw ?? const <String, dynamic>{};
    final planItems = planMap['items'] is List
        ? planMap['items'] as List
        : const [];
    Map? currentPlanItem;
    Map? completedPlanItem;
    for (final item in planItems) {
      if (item is! Map) continue;
      if (currentPlanItem == null &&
          (item['status'] == 'inProgress' || item['status'] == 'pending')) {
        currentPlanItem = item;
      }
      if (item['status'] == 'completed') completedPlanItem = item;
    }

    final goalRaw = state.goal;
    final Map<String, dynamic> goalMap =
        goalRaw ?? const <String, dynamic>{};
    String? goalTitle;
    String? goalStatus;
    goalStatus = '${goalMap['status'] ?? ''}';
    goalTitle = '${goalMap['summaryTitle'] ?? goalMap['objective'] ?? ''}'.trim();
    if (goalTitle.isEmpty) goalTitle = null;
    final activeGoal = ['active', 'notSatisfied', 'paused', 'verifying']
        .contains(goalStatus);
    final doneGoal = goalStatus == 'verified';

    final runningWorkflowCount = workflows.length;
    final runningBashCount = bashes.length;
    final runningSubagents = _runningSubagentCount();
    final runningCount =
        runningWorkflowCount + runningBashCount + runningSubagents;
    final kinds = [
      runningWorkflowCount > 0,
      runningBashCount > 0,
      runningSubagents > 0,
    ].where((b) => b).length;
    final runningIcon = kinds > 1
        ? Icons.bolt
        : runningWorkflowCount > 0
            ? Icons.account_tree_outlined
            : runningBashCount > 0
                ? Icons.terminal_outlined
                : Icons.smart_toy_outlined;

    Widget metric(Map? item, {IconData? icon, Color? iconColor}) {
      final content = '${item?['content'] ?? item?['title'] ?? ''}';
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: iconColor ?? ZInk.solid(context)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(content,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: ZInk.solid(context))),
          ),
          const SizedBox(width: 4),
          Icon(Icons.open_in_full, size: 12, color: ZInk.faint(context)),
        ],
      );
    }

    // 1) current plan step → 2) active goal → 3) last completed step →
    // 4) done goal → 5) plan progress → 6) running background count.
    if (currentPlanItem != null) {
      return metric(currentPlanItem, icon: Icons.arrow_right_alt);
    }
    if (goalTitle != null && activeGoal) {
      return metric({'content': goalTitle}, icon: Icons.track_changes);
    }
    if (completedPlanItem != null) {
      return metric(completedPlanItem,
          icon: Icons.check_circle, iconColor: ZColors.success);
    }
    if (goalTitle != null && doneGoal) {
      return metric({'content': goalTitle}, icon: Icons.track_changes);
    }
    if (planItems.isNotEmpty) {
      final done = planItems
          .where((i) => i is Map && i['status'] == 'completed')
          .length;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.checklist, size: 16, color: ZInk.faint(context)),
          const SizedBox(width: 6),
          Text(tr(context, 'chat.statusPanel.todo'),
              style: TextStyle(fontSize: 12.5, color: ZInk.solid(context))),
          const SizedBox(width: 4),
          Text('$done/${planItems.length}',
              style: TextStyle(fontSize: 12.5, color: ZInk.muted(context))),
          const SizedBox(width: 4),
          Icon(Icons.open_in_full, size: 12, color: ZInk.faint(context)),
        ],
      );
    }
    if (runningCount > 0) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(runningIcon, size: 16, color: ZInk.solid(context)),
          const SizedBox(width: 6),
          Text(
            trP(context, 'chat.status.section.runningCount',
                ['$runningCount']),
            style: TextStyle(fontSize: 12.5, color: ZInk.solid(context)),
          ),
          const SizedBox(width: 4),
          Icon(Icons.open_in_full, size: 12, color: ZInk.faint(context)),
        ],
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final runningSubagents = _runningSubagentCount();
    final hasContent = _probeGit() != null ||
        _workflowRows().isNotEmpty ||
        state.backgroundWorks.isNotEmpty ||
        runningSubagents > 0 ||
        state.plan != null ||
        state.goal != null;
    if (!hasContent) return const SizedBox.shrink();
    if (!_expanded) {
      final metric = _capsuleMetric(context);
      if (metric == null) return const SizedBox.shrink();
      // Official mini variant: w-max max-w-80 capsule, top of the
      // conversation, right-aligned; tap expands the full sections card.
      return Align(
        alignment: Alignment.centerRight,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = true),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
            child: metric,
          ),
        ),
      );
    }
    return _expandedPanel(context);
  }

  Widget _expandedPanel(BuildContext context) {
    final git = _probeGit();
    final workflows = _workflowRows();
    final bashes = state.backgroundWorks
        .where((w) => w['kind'] == 'bash' && w['status'] == 'running')
        .toList();
    if (git == null && workflows.isEmpty && bashes.isEmpty) {
      return const SizedBox.shrink();
    }
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          if (git != null) _GitRow(git: git),
          if (workflows.isNotEmpty) ...[
            _sectionHeader(
              key: 'workflow',
              title: tr(context, 'chat.status.section.workflows'),
              count: workflows.length,
              elapsed: _longestElapsed(workflows),
            ),
            if (_openSections.contains('workflow'))
              for (final run in workflows)
                _WorkflowRow(
                  run: run,
                  onCancel: (workId) =>
                      gateway.cancelBackgroundWork(sessionId, workId),
                ),
          ],
          if (bashes.isNotEmpty) ...[
            _sectionHeader(
              key: 'terminal',
              title: tr(context, 'chat.status.section.terminals'),
              count: bashes.length,
              elapsed: _longestElapsed(bashes),
            ),
            if (_openSections.contains('terminal'))
              for (final work in bashes)
                _BashRow(
                  work: work,
                  onCancel: (workId) =>
                      gateway.cancelBackgroundWork(sessionId, workId),
                ),
          ],
        ],
      ),
    );
  }
}

class _GitRow extends StatelessWidget {
  final Map git;

  const _GitRow({required this.git});

  @override
  Widget build(BuildContext context) {
    final branch = '${git['branchName'] ?? git['branch'] ?? ''}';
    final ahead = (git['ahead'] as num?)?.toInt() ?? 0;
    final behind = (git['behind'] as num?)?.toInt() ?? 0;
    final dirty = (git['dirtyFileCount'] ?? git['gitDirtyFileCount']) as num?;
    final summary = git['gitWorktreeChangeSummary'];
    final added = summary is Map ? (summary['added'] as num?)?.toInt() : null;
    final removed =
        summary is Map ? (summary['removed'] as num?)?.toInt() : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.account_tree_outlined,
              size: 13, color: ZInk.muted(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              branch,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: ZInk.soft(context)),
            ),
          ),
          if (ahead > 0)
            Text('↑$ahead',
                style: const TextStyle(fontSize: 11, color: ZColors.success)),
          if (behind > 0)
            Text('  ↓$behind',
                style: TextStyle(fontSize: 11, color: ZColors.warning)),
          if (dirty != null && dirty > 0)
            Text(
              trP(context, 'chat.status.gitDirty', ['$dirty']),
              style: TextStyle(fontSize: 11, color: ZInk.muted(context)),
            )
          else if (added != null && removed != null && added + removed > 0)
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                      text: ' +', style: TextStyle(color: ZColors.success)),
                  TextSpan(text: '$added'),
                  const TextSpan(
                      text: ' -', style: TextStyle(color: ZColors.danger)),
                  TextSpan(text: '$removed'),
                ],
                style: const TextStyle(fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

/// Workflow status-dot/word palette (web run-status-presentation.ts):
/// running reads as "active" (warning, not primary); pending/stopped are
/// hollow; completed success; errored destructive. Status always has a
/// word — never color alone.
class _RunStatusStyle {
  final Color dotFill;
  final Color dotBorder;
  final Color text;

  const _RunStatusStyle({
    required this.dotFill,
    required this.dotBorder,
    required this.text,
  });

  static _RunStatusStyle of(BuildContext context, String status) =>
      switch (status) {
        'running' => _RunStatusStyle(
            dotFill: ZColors.warning,
            dotBorder: ZColors.warning,
            text: ZColors.warning,
          ),
        'completed' => _RunStatusStyle(
            dotFill: ZColors.success,
            dotBorder: ZColors.success,
            text: ZColors.success,
          ),
        'errored' => _RunStatusStyle(
            dotFill: ZColors.danger,
            dotBorder: ZColors.danger,
            text: ZColors.danger,
          ),
        _ => _RunStatusStyle(
            // pending / stopped: hollow dot, muted word.
            dotFill: Colors.transparent,
            dotBorder: ZInk.faint(context),
            text: ZInk.muted(context),
          ),
      };
}

/// Shared elapsed label (web formatBackgroundTaskElapsedLabel): "已运行
/// m 分 ss 秒" above a minute, "已运行 s 秒" below.
String? _elapsedLabel(BuildContext context, Map row, int nowMs) {
  final startedAt = (row['startedAt'] as num?)?.toInt();
  if (startedAt == null) return null;
  final totalSeconds =
      ((nowMs - startedAt) ~/ 1000).clamp(1, 1 << 31);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (minutes > 0) {
    return trP(context, 'goalPanel.runningFor',
        ['$minutes', seconds.toString().padLeft(2, '0')]);
  }
  return trP(context, 'goalPanel.duration.s', ['$seconds']);
}

/// Official WorkflowStatusSection row: name on top; meta line below with
/// status dot + status word + "done/total 步" + elapsed ticker + Stop.
/// Projection order is preserved (never re-sorted); the elapsed clock
/// ticks every second only while a startedAt row is on screen.
class _WorkflowRow extends StatefulWidget {
  final Map run;
  final void Function(String workId) onCancel;

  const _WorkflowRow({required this.run, required this.onCancel});

  @override
  State<_WorkflowRow> createState() => _WorkflowRowState();
}

class _WorkflowRowState extends State<_WorkflowRow> {
  Timer? _ticker;
  int _nowMs = DateTime.now().millisecondsSinceEpoch;

  void _ensureTicker(bool hasStart) {
    if (hasStart && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _nowMs = DateTime.now().millisecondsSinceEpoch);
        }
      });
    } else if (!hasStart && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _ensureTicker(widget.run['startedAt'] != null);
  }

  @override
  void didUpdateWidget(_WorkflowRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureTicker(widget.run['startedAt'] != null);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    final runId = '${run['runId'] ?? ''}';
    final workId = '${run['workId'] ?? ''}';
    final title = '${run['title'] ?? ''}';
    // Unnamed = title absent or title ≡ runId (core's taskId fallback);
    // one comparison covers degraded rows too.
    final displayName = title.isNotEmpty && title != runId
        ? title
        : tr(context, 'chat.status.workflowUnnamed');
    final status = '${run['status'] ?? ''}';
    final hasStatus = status == 'pending' || status == 'running';
    final total = asWorkflowInt(run['nodesTotal']) ?? 0;
    final settled = asWorkflowInt(run['nodesSettled']) ?? 0;
    final style = _RunStatusStyle.of(context, status);
    final cancellable = run['cancellable'] == true && workId.isNotEmpty;
    final elapsed = _elapsedLabel(context, run, _nowMs);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.account_tree_outlined,
                size: 15, color: ZInk.muted(context)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: ZInk.solid(context)),
                ),
                const SizedBox(height: 3),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 2,
                  children: [
                    if (hasStatus) ...[
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: style.dotFill,
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: style.dotBorder, width: 1.2),
                        ),
                      ),
                      Text(
                        tr(context, 'chat.workflow.status.$status'),
                        style: TextStyle(fontSize: 12, color: style.text),
                      ),
                      Text(
                        trP(context, 'chat.status.workflowSteps',
                            ['$settled', '$total']),
                        style: TextStyle(
                            fontSize: 12, color: ZInk.muted(context)),
                      ),
                    ],
                    if (elapsed != null)
                      Text(elapsed,
                          style: TextStyle(
                              fontSize: 12, color: ZInk.muted(context))),
                    if (cancellable)
                      Tooltip(
                        message: tr(context, 'chat.bgWorks.cancel'),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => widget.onCancel(workId),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(Icons.close,
                                size: 14, color: ZInk.muted(context)),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Terminal row (web Terminals section): title + elapsed ticker + Stop.
class _BashRow extends StatefulWidget {
  final Map work;
  final void Function(String workId) onCancel;

  const _BashRow({required this.work, required this.onCancel});

  @override
  State<_BashRow> createState() => _BashRowState();
}

class _BashRowState extends State<_BashRow> {
  Timer? _ticker;
  int _nowMs = DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    if (widget.work['startedAt'] != null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _nowMs = DateTime.now().millisecondsSinceEpoch);
        }
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final work = widget.work;
    final workId = '${work['workId'] ?? work['id'] ?? ''}';
    final elapsed = _elapsedLabel(context, work, _nowMs);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.terminal_outlined, size: 14, color: ZInk.muted(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${work['title'] ?? tr(context, 'chat.status.bash')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: ZInk.solid(context)),
            ),
          ),
          if (elapsed != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(elapsed,
                  style:
                      TextStyle(fontSize: 12, color: ZInk.muted(context))),
            ),
          if (workId.isNotEmpty)
            Tooltip(
              message: tr(context, 'chat.bgWorks.cancel'),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => widget.onCancel(workId),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child:
                      Icon(Icons.close, size: 14, color: ZInk.muted(context)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class QueueBar extends StatelessWidget {
  final ConversationState state;
  final ChatGateway gateway;

  const QueueBar({super.key, required this.state, required this.gateway});

  @override
  Widget build(BuildContext context) {
    final items = state.queueItems;
    if (items.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ZColors.sky500.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.sky500.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.queue_outlined, size: 14, color: ZColors.sky500),
              const SizedBox(width: 6),
              Text(
                trP(context, 'chat.queue.count', ['${items.length}']),
                style: const TextStyle(fontSize: 12, color: ZColors.sky500),
              ),
              const Spacer(),
              InkWell(
                onTap: () {
                  final next = !state.autoDrain;
                  state.optimisticPatch({
                    'queue': {...?state.queue, 'autoDrain': next},
                  });
                  gateway.setAutoDrain(sessionId, next);
                },
                child: Text(
                  state.autoDrain
                      ? tr(context, 'chat.queue.autoOn')
                      : tr(context, 'chat.queue.autoOff'),
                  style: TextStyle(fontSize: 11, color: ZInk.muted(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${items[i]['text'] ?? ''}',
                      style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _QueueAction(
                    icon: Icons.arrow_upward,
                    tooltip: tr(context, 'chat.queue.moveUp'),
                    enabled: i > 0,
                    onTap: () => _reorder(context, sessionId, items, i, i - 1),
                  ),
                  _QueueAction(
                    icon: Icons.arrow_downward,
                    tooltip: tr(context, 'chat.queue.moveDown'),
                    enabled: i < items.length - 1,
                    onTap: () => _reorder(context, sessionId, items, i,
                        i + 2 >= items.length ? null : i + 2),
                  ),
                  _QueueAction(
                    icon: Icons.play_arrow,
                    tooltip: tr(context, 'chat.queue.sendNow'),
                    onTap: () {
                      final id = '${items[i]['queueItemId']}';
                      state.optimisticRemoveQueueItem(id);
                      gateway.sendQueuedNow(sessionId, id);
                    },
                  ),
                  _QueueAction(
                    icon: Icons.edit_outlined,
                    tooltip: tr(context, 'chat.queue.edit'),
                    onTap: () => _edit(context, sessionId, items[i]),
                  ),
                  _QueueAction(
                    icon: Icons.close,
                    tooltip: tr(context, 'devices.menu.delete'),
                    onTap: () async {
                      final id = '${items[i]['queueItemId']}';
                      final confirmed = await showDialog<bool>(
                        context: context,
                        useRootNavigator: false,
                        builder: (context) => AlertDialog(
                          title: Text(tr(context, 'chat.queue.delete.title')),
                          content: Text(
                            '${items[i]['text'] ?? ''}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(tr(context, 'devices.add.cancel')),
                            ),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: ZColors.danger,
                              ),
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(
                                tr(context, 'devices.delete.confirm'),
                              ),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                      state.optimisticRemoveQueueItem(id);
                      gateway.deleteQueueItem(sessionId, id);
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Web drag-to-reorder parity: the same `reorderQueueItem
  /// {queueItemId, beforeQueueItemId|null}` command, driven by move
  /// buttons (rows are too narrow for a drag handle on phones).
  /// [targetIndex] is the index the item should occupy after the move;
  /// `null` moves it to the end.
  void _reorder(
    BuildContext context,
    String sessionId,
    List<Map<String, dynamic>> items,
    int index,
    int? targetIndex,
  ) {
    if (targetIndex != null &&
        (targetIndex < 0 || targetIndex > items.length)) {
      return;
    }
    final id = '${items[index]['queueItemId']}';
    final String? beforeId;
    if (targetIndex == null) {
      beforeId = null;
    } else if (targetIndex == items.length) {
      beforeId = null;
    } else {
      beforeId = '${items[targetIndex]['queueItemId']}';
    }
    gateway.reorderQueueItem(sessionId, id, beforeId);
  }

  Future<void> _edit(
    BuildContext context,
    String sessionId,
    Map<String, dynamic> item,
  ) async {
    final controller = TextEditingController(text: '${item['text'] ?? ''}');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.queue.edit.title')),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'devices.add.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr(context, 'devices.rename.save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    // Optimistic text update; server queue patch confirms.
    final q = state.queue;
    if (q != null && q['items'] is List) {
      final items = [
        for (final i in q['items'] as List)
          if (i is Map && '${i['queueItemId']}' == '${item['queueItemId']}')
            {...i, 'text': text}
          else
            i,
      ];
      state.optimisticPatch({
        'queue': {...q, 'items': items},
      });
    }
    await gateway.editQueueItem(sessionId, '${item['queueItemId']}', text);
  }
}

class _QueueAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  const _QueueAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        icon,
        size: 16,
        color: enabled ? ZInk.muted(context) : ZInk.ghost(context),
      ),
      tooltip: tooltip,
      onPressed: enabled ? onTap : null,
      visualDensity: VisualDensity.compact,
    );
  }
}
