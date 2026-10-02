import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../protocol/conversation.dart';
import '../../protocol/workflow_runs.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'markdown_view.dart';
import 'workflow_card.dart';

/// Workflow run details (web WorkflowRunSidePane, mobile page form): the
/// status header (name, Resume/Stop, lamp + word, usage, lineage), the
/// vertical phase spine with per-phase participant pills, the artifacts
/// section and outstanding questions. Live state re-reads the conversation
/// snapshot on every frame (web re-subscribes the same projection).
class WorkflowRunPage extends StatefulWidget {
  final ChatGateway gateway;
  final String sessionId;
  final ConversationState? state;
  final Map<String, dynamic> run;

  const WorkflowRunPage({
    super.key,
    required this.gateway,
    required this.sessionId,
    this.state,
    required this.run,
  });

  @override
  State<WorkflowRunPage> createState() => _WorkflowRunPageState();
}

class _WorkflowRunPageState extends State<WorkflowRunPage> {
  List<Map<String, dynamic>> _artifacts = const [];
  bool _artifactsLoaded = false;
  int _loadedAtSequence = -1;
  bool _busy = false;

  WorkflowRun? _liveRun;

  @override
  void initState() {
    super.initState();
    _loadArtifacts();
  }

  /// Re-reads the run from the live snapshot (fresh status/actors/nodes).
  WorkflowRun? _currentRun() {
    final runId = WorkflowRun(widget.run).runId;
    final workflowRuns = widget.state?.snapshot?['workflowRuns'];
    final runs = workflowRuns is Map ? workflowRuns['runs'] : null;
    if (runs is List) {
      for (final candidate in runs) {
        if (candidate is Map &&
            '${candidate['runId'] ?? ''}' == runId) {
          return WorkflowRun(candidate.cast<String, dynamic>());
        }
      }
    }
    return _liveRun;
  }

  Future<void> _loadArtifacts() async {
    final run = _currentRun();
    if (run == null || run.runId.isEmpty) return;
    final artifacts = await widget.gateway.runArtifacts(
      widget.sessionId,
      run.runId,
    );
    if (!mounted) return;
    setState(() {
      _artifacts = artifacts;
      _artifactsLoaded = true;
      _loadedAtSequence = run.lastEventSequence;
    });
  }

  Future<void> _resume() async {
    if (_busy) return;
    final run = _currentRun();
    if (run == null) return;
    setState(() => _busy = true);
    try {
      final res = await widget.gateway.resumeWorkflowRun(
        widget.sessionId,
        run.runId,
      );
      if (!mounted) return;
      if (res is Map && res['status'] != null && res['status'] != 'accepted') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trP(context, 'wrp.action.rejected',
                ['${res['reasonCode'] ?? res['status']}'])),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    if (_busy) return;
    final run = _currentRun();
    if (run == null) return;
    setState(() => _busy = true);
    try {
      await widget.gateway.cancelBackgroundWork(widget.sessionId, run.runId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state ?? widget.gateway,
      builder: (context, _) {
        final run = _currentRun() ?? WorkflowRun(widget.run);
        // Artifacts refresh when the journal watermark advances.
        if (_artifactsLoaded &&
            run.lastEventSequence > _loadedAtSequence &&
            run.live) {
          scheduleMicrotask(_loadArtifacts);
        }
        return Scaffold(
          appBar: AppBar(title: Text(tr(context, 'wrp.title'))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
            children: [
              _header(context, run),
              const SizedBox(height: 10),
              _spineSection(context, run),
              const SizedBox(height: 10),
              _artifactsSection(context, run),
              if (run.pendingQuestions.isNotEmpty) ...[
                const SizedBox(height: 10),
                _questionsSection(context, run),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, WorkflowRun run) {
    final lamp = _runLamp(context, run.status);
    final statusWord = switch (run.status) {
      'pending' => tr(context, 'chat.workflow.status.pending'),
      'running' => tr(context, 'chat.workflow.status.running'),
      'completed' => tr(context, 'chat.workflow.status.completed'),
      'errored' => tr(context, 'chat.workflow.status.errored'),
      'stopped' => tr(context, 'chat.workflow.status.stopped'),
      _ => run.status,
    };
    final name =
        run.raw['label'] ?? run.raw['title'] ?? tr(context, 'wrp.fallbackName');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: ZInk.solid(context),
                  ),
                ),
              ),
              if (run.live)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero,
                  ),
                  onPressed: _busy ? null : _stop,
                  child: Text(tr(context, 'wrp.stop'),
                      style: const TextStyle(fontSize: 12)),
                ),
              if (run.resumable) ...[
                const SizedBox(width: 6),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: ZColors.sky500,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero,
                  ),
                  onPressed: _busy ? null : _resume,
                  child: Text(tr(context, 'wrp.resume'),
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 2,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: lamp.$1,
                  shape: BoxShape.circle,
                  border: Border.all(color: lamp.$2, width: 1.4),
                ),
              ),
              Text(statusWord,
                  style: TextStyle(fontSize: 12, color: lamp.$3)),
              if (run.stopReason.isNotEmpty)
                Text(
                  '· ${tr(context, 'chat.workflow.stop.${run.stopReason}')}',
                  style: TextStyle(fontSize: 12, color: ZInk.faint(context)),
                ),
              if (run.resumable)
                Text(
                  '· ${tr(context, 'chat.workflow.run.resumable')}',
                  style: TextStyle(fontSize: 12, color: ZInk.faint(context)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            trP(context, 'wrp.usage',
                ['${run.spentTokens}', '${run.nodesUsed}']),
            style: TextStyle(fontSize: 12, color: ZInk.muted(context)),
          ),
          if (run.raw['resumedFrom'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                trP(context, 'wrp.lineage', ['${run.raw['resumedFrom']}']),
                style: TextStyle(fontSize: 11.5, color: ZInk.faint(context)),
              ),
            ),
        ],
      ),
    );
  }

  /// Vertical phase spine (web WorkflowRunPhaseList, lite): one rail on the
  /// left, a lamp per station, the running station's pills shown inline.
  Widget _spineSection(BuildContext context, WorkflowRun run) {
    final graph = _graph();
    final phasesRaw = graph is Map ? graph['phases'] : null;
    final track = <_SpineStation>[
      if (phasesRaw is List)
        for (final phase in phasesRaw)
          if (phase is Map)
            _SpineStation(
              key: '${phase['id'] ?? ''}',
              name: '${phase['name'] ?? ''}'.trim().isNotEmpty
                  ? '${phase['name']}'
                  : tr(context, 'chat.workflow.card.unphased'),
            ),
      if (phasesRaw is! List)
        for (final name in run.phaseNames) _SpineStation(key: name, name: name),
    ];
    if (track.isEmpty) return const SizedBox.shrink();

    var currentIdx = -1;
    if (run.currentPhase.isNotEmpty) {
      for (var i = 0; i < track.length; i++) {
        if (WorkflowRun.phaseNameMatches(track[i].name, run.currentPhase) ||
            WorkflowRun.phaseNameMatches(track[i].key, run.currentPhase)) {
          currentIdx = i;
          break;
        }
      }
    }

    _SpineState stationState(int index) {
      if (run.status == 'completed') return _SpineState.done;
      if (run.status == 'errored' && run.currentPhase.isEmpty) {
        return _SpineState.failed;
      }
      final station = track[index];
      final hard = aggregateStatuses([
        for (final node in run.nodes)
          if (WorkflowRun.phaseNameMatches(node.phaseName, station.name) ||
              WorkflowRun.phaseNameMatches(node.phaseName, station.key))
            nodeStepStatus(node),
      ]);
      if (hard == WorkflowStepStatus.running) return _SpineState.running;
      if (hard == WorkflowStepStatus.failed) return _SpineState.failed;
      if (index == currentIdx) {
        return run.live ? _SpineState.running : _SpineState.done;
      }
      if (index < currentIdx) return _SpineState.done;
      if (hard == WorkflowStepStatus.done) return _SpineState.done;
      if (run.enteredPhase(station.name)) return _SpineState.done;
      return _SpineState.pending;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(context, 'wrp.phases'),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        for (var i = 0; i < track.length; i++)
          _spineRow(context, run, track[i], stationState(i),
              hasLineBelow: i < track.length - 1),
      ],
    );
  }

  Widget _spineRow(
    BuildContext context,
    WorkflowRun run,
    _SpineStation station,
    _SpineState state, {
    required bool hasLineBelow,
  }) {
    final (fill, border) = switch (state) {
      _SpineState.running => (ZColors.warning, ZColors.warning),
      _SpineState.done => (ZColors.success, ZColors.success),
      _SpineState.failed => (ZColors.danger, ZColors.danger),
      _ => (Colors.transparent, ZInk.faint(context)),
    };
    final labelColor = switch (state) {
      _SpineState.running => ZColors.warning,
      _SpineState.pending => ZInk.muted(context),
      _ => ZInk.solid(context),
    };
    // Participants of this phase: actors born into it (phaseName match).
    final phaseActors = [
      for (final actor in run.actors)
        if (WorkflowRun.phaseNameMatches(actor.phaseName, station.name) ||
            WorkflowRun.phaseNameMatches(actor.phaseName, station.key))
          actor,
    ];
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Rail column: vertical line + lamp.
          SizedBox(
            width: 24,
            child: Stack(
              children: [
                if (hasLineBelow)
                  Positioned(
                    left: 10,
                    top: 12,
                    bottom: 0,
                    width: 1.6,
                    child: Container(color: ZInk.hairline(context)),
                  ),
                Positioned(
                  top: 6,
                  left: 4,
                  child: Container(
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                      color: fill,
                      shape: BoxShape.circle,
                      border: Border.all(color: border, width: 1.6),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(station.name,
                        style: TextStyle(
                            fontSize: 12.5, color: labelColor)),
                  ),
                  for (final actor in phaseActors)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Container(
                        height: 30,
                        padding: const EdgeInsets.fromLTRB(6, 0, 8, 0),
                        decoration: BoxDecoration(
                          color: ZInk.codeBlockBg(context),
                          borderRadius: BorderRadius.circular(15),
                          border:
                              Border.all(color: ZInk.hairline(context)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AgentFace(
                              name: actor.name.isEmpty
                                  ? station.name
                                  : actor.name,
                              color: agentColor(
                                  actor.name.isEmpty
                                      ? station.name
                                      : actor.name),
                              expression: switch (actor.status) {
                                'running' => FaceExpression.scanning,
                                'completed' => FaceExpression.happy,
                                _ => FaceExpression.waiting,
                              },
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                actor.name.isEmpty
                                    ? tr(context,
                                        'chat.workflow.card.noAgents')
                                    : actor.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11.5,
                                    color: ZInk.soft(context)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _artifactsSection(BuildContext context, WorkflowRun run) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(context, 'wrp.artifacts'),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (!_artifactsLoaded)
          const Center(
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 1.6)))
        else if (_artifacts.isEmpty)
          Text(tr(context, 'wrp.artifacts.empty'),
              style: TextStyle(fontSize: 12, color: ZInk.muted(context)))
        else
          for (final artifact in _artifacts)
            _ArtifactTile(
              artifact: artifact,
              gateway: widget.gateway,
              sessionId: widget.sessionId,
              runId: run.runId,
            ),
      ],
    );
  }

  Widget _questionsSection(BuildContext context, WorkflowRun run) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(context, 'wrp.questions'),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (final question in run.pendingQuestions)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: ZColors.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: ZColors.warning.withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${question['question'] ?? ''}',
                  style: TextStyle(fontSize: 12.5, color: ZInk.solid(context)),
                ),
                if (question['actorName'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${question['actorName']}',
                      style:
                          TextStyle(fontSize: 11, color: ZInk.faint(context)),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Static causal graph from the CreateWorkflow tool row (web
  /// buildWorkflowGraphByToolCallId join over snapshot rows).
  Map? _graph() {
    final toolCallId = _currentRun()?.toolCallId ?? '';
    if (toolCallId.isEmpty) return null;
    for (final row in widget.state?.rows ?? const <Map<String, dynamic>>[]) {
      if (row['kind'] != 'toolCall') continue;
      if ('${row['toolCallId'] ?? ''}' != toolCallId) continue;
      final display = row['display'];
      if (display is Map && display['causalityGraph'] is Map) {
        return display['causalityGraph'] as Map;
      }
    }
    return null;
  }
}

class _SpineStation {
  final String key;
  final String name;
  const _SpineStation({required this.key, required this.name});
}

enum _SpineState { pending, running, done, failed }

(Color, Color, Color) _runLamp(BuildContext context, String status) {
  return switch (status) {
    'running' => (ZColors.warning, ZColors.warning, ZColors.warning),
    'completed' => (ZColors.success, ZColors.success, ZColors.success),
    'errored' => (ZColors.danger, ZColors.danger, ZColors.danger),
    _ => (Colors.transparent, ZInk.faint(context), ZInk.muted(context)),
  };
}

/// Expandable artifact tile: summary chip → inline body loaded on demand
/// (bytes for markdown/image/text; item list for preset boards).
class _ArtifactTile extends StatefulWidget {
  final Map<String, dynamic> artifact;
  final ChatGateway gateway;
  final String sessionId;
  final String runId;

  const _ArtifactTile({
    required this.artifact,
    required this.gateway,
    required this.sessionId,
    required this.runId,
  });

  @override
  State<_ArtifactTile> createState() => _ArtifactTileState();
}

class _ArtifactTileState extends State<_ArtifactTile> {
  bool _expanded = false;
  bool _loading = false;
  Uint8List? _bytes;
  String? _mediaType;
  List<Map<String, dynamic>> _items = const [];
  String? _error;

  String get _kind => '${widget.artifact['kind'] ?? 'file'}';
  String get _title =>
      '${widget.artifact['title'] ?? widget.artifact['id'] ?? _kind}';
  bool get _isPreset =>
      ['chart', 'table', 'metrics', 'board'].contains(_kind);

  Future<void> _toggle() async {
    setState(() => _expanded = !_expanded);
    if (!_expanded || _loading || _bytes != null || _items.isNotEmpty) return;
    setState(() => _loading = true);
    try {
      if (_isPreset) {
        _items = await widget.gateway.runArtifactData(
          widget.sessionId,
          widget.runId,
          '${widget.artifact['id'] ?? ''}',
        );
      } else {
        final bytes = await widget.gateway.runArtifactBytes(
          widget.sessionId,
          widget.runId,
          widget.artifact,
        );
        _bytes = bytes?.bytes;
        _mediaType = bytes?.mediaType;
      }
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = switch (_kind) {
      'markdown' => Icons.description_outlined,
      'chart' => Icons.bar_chart_outlined,
      'table' => Icons.table_chart_outlined,
      'metrics' => Icons.query_stats_outlined,
      'board' => Icons.dashboard_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Icon(icon, size: 14, color: ZInk.muted(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, color: ZInk.solid(context)),
                    ),
                  ),
                  Text(
                    'v${widget.artifact['version'] ?? 1}',
                    style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: ZInk.muted(context),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: _body(context),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Center(
          child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.6)));
    }
    if (_error != null) {
      return Text(_error!,
          style: TextStyle(fontSize: 11.5, color: ZColors.danger));
    }
    if (_isPreset) {
      return Text(
        trP(context, 'wrp.artifacts.items', ['${_items.length}']),
        style: TextStyle(fontSize: 12, color: ZInk.muted(context)),
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return Text(tr(context, 'wrp.artifacts.empty'),
          style: TextStyle(fontSize: 12, color: ZInk.muted(context)));
    }
    final mediaType = _mediaType ?? '';
    if (mediaType.startsWith('image/')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(bytes, fit: BoxFit.contain),
      );
    }
    if (mediaType.contains('markdown')) {
      return ZLinkerMarkdown(utf8.decode(bytes, allowMalformed: true));
    }
    // text/*, json, csv and unknown text-likes render as code text.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ZInk.codeBlockBg(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        utf8.decode(bytes, allowMalformed: true),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: ZInk.solid(context),
        ),
      ),
    );
  }
}
