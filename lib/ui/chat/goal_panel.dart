import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../protocol/conversation.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// Web 目标面板 parity (chat.statusPanel.* / goalBanner.*): the active
/// goal's summary + elapsed + iteration progress, the plan's process list
/// (completed items collapsed), and running subagents with elapsed time.
///
/// Data comes straight from the conversation snapshot: `goal`
/// ({summaryTitle, objective, timeUsedSeconds, status, iterations:[{items:
/// [{content, status}]}]}), `subagents` ({running:[{title, startedAt}]}),
/// `plan` ({items:[{content, status}]}).
class GoalPanel extends StatefulWidget {
  final ConversationState state;
  final Future<void> Function(String sessionId) onPauseGoal;
  final Future<void> Function(String sessionId) onResumeGoal;

  const GoalPanel({
    super.key,
    required this.state,
    required this.onPauseGoal,
    required this.onResumeGoal,
  });

  @override
  State<GoalPanel> createState() => _GoalPanelState();
}

class _GoalPanelState extends State<GoalPanel> {
  bool _showCompleted = false;
  bool _busy = false;

  Map<String, dynamic>? get _goal =>
      (widget.state.snapshot?['goal'] as Map?)?.cast<String, dynamic>();

  Map<String, dynamic>? get _subagents =>
      (widget.state.snapshot?['subagents'] as Map?)?.cast<String, dynamic>();

  List<Map<String, dynamic>> get _runningAgents {
    final list = _subagents?['running'];
    return list is List
        ? list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : const [];
  }

  /// Latest iteration's process items (falls back to plan.items).
  List<Map<String, dynamic>> _processItems(Map<String, dynamic> goal) {
    final iterations = goal['iterations'];
    if (iterations is List && iterations.isNotEmpty) {
      final last = (iterations.last as Map?)?.cast<String, dynamic>();
      final items = last?['items'];
      if (items is List) {
        return items
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      }
    }
    final plan = widget.state.snapshot?['plan'];
    final items = plan is Map ? plan['items'] : null;
    return items is List
        ? items.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : const [];
  }

  static String _fmtDuration(BuildContext context, int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m <= 0) return trP(context, 'goalPanel.duration.s', ['$s']);
    return trP(
        context, 'goalPanel.duration.ms', ['$m', s.toString().padLeft(2, '0')]);
  }

  Future<void> _togglePause(String sessionId, bool paused) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await (paused
          ? widget.onResumeGoal(sessionId)
          : widget.onPauseGoal(sessionId));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final goal = _goal;
    if (goal == null) return const SizedBox.shrink();
    final sessionId = widget.state.snapshot?['sessionId'] as String? ?? '';
    final title = '${goal['summaryTitle'] ?? goal['objective'] ?? ''}'.trim();
    if (title.isEmpty) return const SizedBox.shrink();

    final status = '${goal['status'] ?? 'active'}';
    final paused = status == 'paused';
    final used = (goal['timeUsedSeconds'] as num?)?.toInt() ?? 0;
    final items = _processItems(goal);
    final done = items.where((i) => i['status'] == 'completed').length;
    final total = items.length;

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── header: 目标 · elapsed · pause/resume
          Row(
            children: [
              Text(tr(context, 'goalPanel.title'),
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              if (used > 0)
                Text(_fmtDuration(context, used),
                    style:
                        TextStyle(fontSize: 11.5, color: ZInk.muted(context))),
              const Spacer(),
              InkWell(
                onTap: _busy ? null : () => _togglePause(sessionId, paused),
                child: Icon(
                  paused ? Icons.play_arrow : Icons.pause,
                  size: 16,
                  color: ZInk.muted(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // ── goal summary + progress
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.track_changes,
                  size: 14, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style:
                        TextStyle(fontSize: 12.5, color: ZInk.soft(context))),
              ),
              Text('$done/$total',
                  style: TextStyle(fontSize: 11.5, color: ZInk.muted(context))),
            ],
          ),
          // ── process list
          if (items.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () => setState(() => _showCompleted = !_showCompleted),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      _showCompleted
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 14,
                      color: ZInk.ghost(context),
                    ),
                    const SizedBox(width: 4),
                    Text(trP(context, 'goalPanel.completedN', ['$done']),
                        style: TextStyle(
                            fontSize: 11.5, color: ZInk.muted(context))),
                  ],
                ),
              ),
            ),
            for (final item in items)
              if (_showCompleted || item['status'] != 'completed')
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _stepIcon('${item['status'] ?? ''}'),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${item['content'] ?? item['id'] ?? ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: item['status'] == 'completed'
                                ? ZInk.faint(context)
                                : ZInk.soft(context),
                            decoration: item['status'] == 'completed'
                                ? TextDecoration.lineThrough
                                : TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
          // ── running subagents
          if (_runningAgents.isNotEmpty) ...[
            Divider(height: 16, color: ZInk.hairline(context)),
            Row(
              children: [
                Text(tr(context, 'goalPanel.agents'),
                    style:
                        TextStyle(fontSize: 11.5, color: ZInk.muted(context))),
                const SizedBox(width: 6),
                Text(
                    trP(context, 'goalPanel.agentsRunning',
                        ['${_runningAgents.length}']),
                    style:
                        TextStyle(fontSize: 11.5, color: ZInk.muted(context))),
              ],
            ),
            const SizedBox(height: 4),
            for (final a in _runningAgents)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${a['title'] ?? a['subagentType'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: ZInk.soft(context))),
                    ),
                    _AgentElapsed(startedAt: a['startedAt'] as num?),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _stepIcon(String status) {
    switch (status) {
      case 'completed':
        return const Icon(Icons.check_circle, size: 13, color: ZColors.success);
      case 'inProgress':
        return const SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        );
      default:
        return Icon(Icons.radio_button_unchecked,
            size: 13, color: ZInk.ghost(context));
    }
  }
}

class _AgentElapsed extends StatefulWidget {
  final num? startedAt;
  const _AgentElapsed({this.startedAt});

  @override
  State<_AgentElapsed> createState() => _AgentElapsedState();
}

class _AgentElapsedState extends State<_AgentElapsed> {
  DateTime? _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final started = widget.startedAt?.toInt();
    if (started == null) return const SizedBox.shrink();
    final secs = max(0, (_now?.millisecondsSinceEpoch ?? 0) - started) ~/ 1000;
    final m = secs ~/ 60;
    final s = secs % 60;
    return Text(
        trP(context, 'goalPanel.runningFor',
            ['$m', s.toString().padLeft(2, '0')]),
        style: TextStyle(fontSize: 10.5, color: ZInk.faint(context)));
  }
}
