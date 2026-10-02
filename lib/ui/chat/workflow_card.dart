import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../protocol/conversation.dart';
import '../../protocol/workflow_runs.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// Official geometry constants (web timeline-geometry.ts).
const double kStationWidth = 168;
const double kStationGap = 24;
const double kRailRowHeight = 24;
const double kLampSize = 10;
const double kLampCenterX = 17; // MARK_X: margin 12 + radius 5
const double kCaptionX = 12;
const double kPillHeight = 32;
const double kPillGap = 6;
const int kRosterPins = 5; // ROSTER_PINS_CARD
const int kRosterDeck = 3; // faces stacked on the "还有 n 个" row

/// Workflow card (official create-workflow.tsx parity): header with the
/// phase-kind word, script name and the run-status lamp at the top-right;
/// the body (open by default, web isOpen ?? true) holds the horizontal
/// station timeline — rail lamps carry live execution state folded from
/// `snapshot.workflowRuns.runs[]` (actors/nodes/currentPhase), participant
/// pills stack vertically per station with the nine-color tile faces.
class WorkflowCard extends StatefulWidget {
  final Map<String, dynamic> row;
  final Map<String, dynamic> display;
  final ConversationState? state;

  /// Opens the actor's transcript session (web onOpenPill → actor tab).
  final void Function(String sessionId, String name)? onOpenActor;

  /// Opens the run-details page (web ⤢ / more-row target).
  final void Function(Map<String, dynamic> liveRun)? onOpenRunDetails;

  const WorkflowCard({
    super.key,
    required this.row,
    required this.display,
    this.state,
    this.onOpenActor,
    this.onOpenRunDetails,
  });

  @override
  State<WorkflowCard> createState() => _WorkflowCardState();
}

class _WorkflowCardState extends State<WorkflowCard> {
  @override
  Widget build(BuildContext context) {
    // Real desktop payloads have thrown on shapes my fixtures never covered;
    // degrade to the plain summary card (and log) instead of rendering
    // Flutter's red error widget.
    try {
      return _build(context);
    } catch (error, stack) {
      assert(() {
        // ignore: avoid_print
        print('workflow card build error: $error');
        // ignore: avoid_print
        print(stack);
        return true;
      }());
      return _fallbackCard(context);
    }
  }

  Widget _fallbackCard(BuildContext context) {
    final output = widget.row['output'];
    final outputText = output is Map ? output['text'] as String? ?? '' : '';
    return Material(
      color: ZInk.tile(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(Icons.account_tree_outlined,
            size: 16, color: ZInk.muted(context)),
        title: Text(
          tr(context, 'chat.tool.workflow.kind'),
          style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
        ),
        children: [
          if (outputText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SelectableText(outputText,
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: ZInk.solid(context))),
            ),
        ],
      ),
    );
  }

  Widget _build(BuildContext context) {
    final display = _WorkflowDisplay.from(widget.display);
    if (display == null) {
      // Display shape changed upstream — degrade to the script/output fold.
      return const SizedBox.shrink();
    }
    final status = widget.row['status'] as String? ?? '';
    final inputText = widget.row['inputText'] as String? ?? '';
    final output = widget.row['output'];
    final outputText = output is Map ? output['text'] as String? ?? '' : '';
    final error = widget.row['error'];
    final toolName = '${widget.row['toolName'] ?? ''}'.toLowerCase();
    final amend = toolName.contains('amend');
    final kindWord = switch (status) {
      'running' || 'inputStreaming' || 'pendingApproval' => tr(context, amend
          ? 'chat.workflow.card.kindAmendWriting'
          : 'chat.workflow.card.kindWriting'),
      _ => amend
          ? tr(context, 'chat.workflow.card.kindAmendRan')
          : tr(context, 'chat.workflow.card.kindRan'),
    };

    // Script name from the input contract (web readWorkflowName).
    String? name;
    try {
      final input = jsonDecode(inputText);
      if (input is Map && input['name'] is String) {
        final trimmed = (input['name'] as String).trim();
        if (trimmed.isNotEmpty) name = trimmed;
      }
    } catch (_) {}
    name ??= tr(context, 'chat.status.workflowUnnamed');

    // Run join: toolCallId first (web buildWorkflowRunByToolCallId), then
    // the row's workId ≡ runId.
    final rowToolCallId = '${widget.row['toolCallId'] ?? ''}';
    final workId = '${widget.row['workId'] ?? ''}';
    Map<String, dynamic>? liveRunMap;
    final workflowRuns = widget.state?.snapshot?['workflowRuns'];
    final runs = workflowRuns is Map ? workflowRuns['runs'] : null;
    if (runs is List) {
      for (final run in runs) {
        if (run is! Map) continue;
        if ((rowToolCallId.isNotEmpty &&
                '${run['toolCallId'] ?? ''}' == rowToolCallId) ||
            (workId.isNotEmpty && '${run['runId'] ?? ''}' == workId)) {
          liveRunMap = run.cast<String, dynamic>();
          break;
        }
      }
    }
    final run = liveRunMap == null ? null : WorkflowRun(liveRunMap);
    final liveStatus = run?.status ?? '';
    final running = liveStatus == 'running';
    final lamp = _workflowLamp(context, liveStatus, fallbackOk: display.ok);

    final statusWord = switch (liveStatus) {
      'pending' => tr(context, 'chat.workflow.status.pending'),
      'running' => tr(context, 'chat.workflow.status.running'),
      'completed' => tr(context, 'chat.workflow.status.completed'),
      'errored' => tr(context, 'chat.workflow.status.errored'),
      'stopped' => tr(context, 'chat.workflow.status.stopped'),
      _ => display.ok
          ? tr(context, 'chat.workflow.card.created')
          : tr(context, 'chat.workflow.card.createFailed'),
    };

    final graph = display.graph;
    final phasesRaw = graph is Map ? graph['phases'] : null;
    final phases = phasesRaw is List ? phasesRaw : const [];
    final participantsRaw = graph is Map ? graph['participants'] : null;
    final participants = [
      if (participantsRaw is List)
        for (final p in participantsRaw)
          if (p is Map) p.cast<String, dynamic>(),
    ];

    // Header detail string (web workflowCardDetail): phase count, agent
    // count, and the live "n working" while running. Steps never appear.
    final detailParts = <String>[
      if (phases.isNotEmpty)
        trP(context, 'chat.workflow.card.phases', ['${phases.length}']),
      if (participants.isNotEmpty)
        trP(context, 'chat.workflow.card.agents', ['${participants.length}']),
      if (running)
        trP(context, 'chat.workflow.card.working',
            ['${run?.actors.where((a) => a.status == 'running').length}']),
    ];

    return Material(
      color: ZInk.tile(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExpansionTile(
            dense: true,
            initiallyExpanded: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: Icon(
              Icons.account_tree_outlined,
              size: 16,
              color: running ? ZColors.warning : ZInk.muted(context),
            ),
            title: Row(
              children: [
                Flexible(
                  child: running
                      ? _SweepText(
                          text: kindWord,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        )
                      : Text(
                          kindWord,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: ZInk.solid(context),
                          ),
                        ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: ZInk.soft(context)),
                  ),
                ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      detailParts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: ZInk.muted(context)),
                    ),
                  ),
                  // Run status lamp + word at the TOP-RIGHT (web header
                  // status slot), with stopped-reason / resumable words.
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: lamp.$1,
                      shape: BoxShape.circle,
                      border: Border.all(color: lamp.$2, width: 1.4),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(statusWord,
                      style: TextStyle(fontSize: 12, color: lamp.$3)),
                  if (liveStatus == 'stopped' &&
                      run != null &&
                      run.stopReason.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Text(
                      '· ${tr(context, 'chat.workflow.stop.${run.stopReason}')}',
                      style:
                          TextStyle(fontSize: 12, color: ZInk.faint(context)),
                    ),
                  ],
                  if (run?.resumable == true) ...[
                    const SizedBox(width: 4),
                    Text(
                      '· ${tr(context, 'chat.workflow.run.resumable')}',
                      style:
                          TextStyle(fontSize: 12, color: ZInk.faint(context)),
                    ),
                  ],
                ],
              ),
            ),
            children: [
              if (run != null && phases.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: _stationTimeline(context, graph, phases, run, participants),
                )
              else if (run == null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                  child: Text(
                    tr(context, 'chat.workflow.card.notStarted.body'),
                    style: TextStyle(fontSize: 11.5, color: ZInk.muted(context)),
                  ),
                ),
              if (run != null && run.artifacts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                  child: _artifactStrip(context, run.artifacts),
                ),
              if (!display.ok && display.diagnostics.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final d in display.diagnostics.take(4))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            'L${d['line'] ?? '?'}:C${d['column'] ?? '?'}  ${d['message'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              color: ZColors.danger,
                            ),
                          ),
                        ),
                      if (display.diagnostics.length > 4)
                        Text(
                          trP(context, 'chat.workflow.card.diagnostics',
                              ['${display.errorCount}']),
                          style: TextStyle(
                              fontSize: 11, color: ZInk.faint(context)),
                        ),
                    ],
                  ),
                ),
              if (inputText.isNotEmpty)
                _kvBlock(context, tr(context, 'chat.tool.input'), inputText),
              if (outputText.isNotEmpty)
                _kvBlock(context, tr(context, 'chat.tool.output'), outputText),
              if (error is Map)
                _kvBlock(
                  context,
                  tr(context, 'chat.tool.error'),
                  '${error['code'] ?? ''} ${error['message'] ?? ''}',
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Lane display name (lanes[] name; falls back to the lane id).
  String _laneNameOf(List lanes, String laneId) {
    for (final lane in lanes) {
      if (lane is Map && '${lane['id'] ?? ''}' == laneId) {
        final name = '${lane['name'] ?? ''}'.trim();
        return name.isNotEmpty ? name : laneId;
      }
    }
    return laneId;
  }

  /// Station timeline (web WorkflowTimeline, lite): horizontal rail with
  /// 168px station columns; each column = rail lamp (10px, MARK_X spine) +
  /// phase caption + participant pills stacked vertically (32px, gap 6).
  /// Station lamps and pill marks fold from the run projection.
  Widget _stationTimeline(BuildContext context, Map? graph, List phases,
      WorkflowRun run, List<Map<String, dynamic>> participants) {
    final lanesRaw = graph is Map ? graph['lanes'] : null;
    final lanes = lanesRaw is List ? lanesRaw : const [];
    // Track: graph phases carry id+name and own the pill grouping.
    final stations = <_StationInfo>[];
    for (final phase in phases) {
      if (phase is! Map) continue;
      final name = '${phase['name'] ?? ''}'.trim();
      stations.add(_StationInfo(
        key: '${phase['id'] ?? name}',
        name: name.isNotEmpty ? name : tr(context, 'chat.workflow.card.unphased'),
      ));
    }
    if (stations.isEmpty) {
      for (final name in run.phaseNames) {
        stations.add(_StationInfo(key: name, name: name));
      }
    }
    if (stations.isEmpty) return const SizedBox.shrink();

    // Station state — official stationStatus chain (timeline-model:176):
    // node hard facts (running/failed) first, then currentPhase+live, then
    // entered?done:pending. Completed runs settle every station done.
    _StationState stationState(_StationInfo station) {
      if (run.status == 'completed') return _StationState.done;
      if (run.status == 'errored' && run.currentPhase.isEmpty) {
        return _StationState.failed;
      }
      final stationStatuses = <WorkflowStepStatus>[
        for (final node in run.nodes)
          if (WorkflowRun.phaseNameMatches(node.phaseName, station.name) ||
              WorkflowRun.phaseNameMatches(node.phaseName, station.key))
            nodeStepStatus(node),
      ];
      final hard = aggregateStatuses(stationStatuses);
      if (hard == WorkflowStepStatus.running) return _StationState.running;
      if (hard == WorkflowStepStatus.failed) return _StationState.failed;
      if (WorkflowRun.phaseNameMatches(run.currentPhase, station.name) ||
          (run.currentPhase.isEmpty &&
              run.enteredPhase(station.name) &&
              run.live)) {
        return run.live ? _StationState.running : _StationState.done;
      }
      if (hard == WorkflowStepStatus.done) return _StationState.done;
      if (run.enteredPhase(station.name)) return _StationState.done;
      return _StationState.pending;
    }

    // Group participants per station: participant.phase is the phase id
    // (graph path) or the phase name (phaseNames path).
    final stationPills = <List<int>>[
      for (var i = 0; i < stations.length; i++) <int>[],
    ];
    final ungrouped = <int>[];
    for (var i = 0; i < participants.length; i++) {
      final phaseRef = '${participants[i]['phase'] ?? ''}';
      var idx = stations.indexWhere((st) => st.key == phaseRef);
      if (idx < 0) {
        idx = stations.indexWhere((st) => st.name == phaseRef);
      }
      if (idx < 0) {
        ungrouped.add(i);
      } else {
        stationPills[idx].add(i);
      }
    }

    var pillOrdinal = 0;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kCaptionX - 12 + 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < stations.length; i++)
              Padding(
                padding: EdgeInsets.only(right: i == stations.length - 1 ? 0 : kStationGap),
                child: _StationColumn(
                  station: stations[i],
                  state: stationState(stations[i]),
                  pills: [
                    for (final index in stationPills[i])
                      _Enter(
                        ordinal: pillOrdinal++,
                        child: _participantPill(context, run, lanes,
                            participants[index], stationState(stations[i]),
                            stations[i].name),
                      ),
                    // Roster more row (web WorkflowMoreRow): deck faces +
                    // 还有 n 个 — placeholder until run details exist.
                  ],
                  isLast: i == stations.length - 1,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _participantPill(
    BuildContext context,
    WorkflowRun run,
    List lanes,
    Map<String, dynamic> participant,
    _StationState stationState,
    String stationName,
  ) {
    final member = participant['member'] is Map
        ? participant['member'] as Map
        : null;
    var name = _laneNameOf(lanes, '${participant['lane'] ?? ''}');
    if (participant['many'] == true) {
      name = '$name ×';
    } else if (member != null) {
      final index = asWorkflowInt(member['index']) ?? 0;
      final of = asWorkflowInt(member['of']) ?? 0;
      name = of > 0 ? '$name ${index + 1}/$of' : name;
    }

    // Live mark: aggregate the participant's nodes (actor binding + step
    // site narrowing when the graph lists step ids). No run → static pill
    // (pixel-identical to pending, web invariant 3).
    final stepIds = [
      if (participant['steps'] is List)
        for (final s in participant['steps'] as List) '$s',
    ];
    _PillMark mark = _PillMark.none;
    if (stationState == _StationState.done) {
      mark = _PillMark.done;
    } else if (stationState == _StationState.failed) {
      mark = _PillMark.failed;
    } else if (stationState == _StationState.running) {
      // Narrow to this participant's steps (graph step ids ≡ node
      // siteIds).
      WorkflowStepStatus? aggregate;
      for (final node in run.nodes) {
        final inSteps = stepIds.isEmpty || stepIds.contains('${node.siteId}');
        if (!inSteps) continue;
        aggregate = aggregateStatuses([
          if (aggregate != null) aggregate,
          nodeStepStatus(node),
        ]);
      }
      mark = switch (aggregate) {
        WorkflowStepStatus.running => _PillMark.running,
        WorkflowStepStatus.done => _PillMark.done,
        WorkflowStepStatus.failed => _PillMark.failed,
        _ => _PillMark.none,
      };
    }

    // Actor session for the transcript jump: prefer the name match (the
    // runtime actor name is the lane display name), then the phase binding.
    WorkflowRunActor? actor;
    for (final a in run.actors) {
      if (a.name.isNotEmpty && a.name == name) {
        actor = a;
        break;
      }
    }
    actor ??= run.actors.firstWhere(
      (a) => WorkflowRun.phaseNameMatches(a.phaseName, stationName),
      orElse: () => run.actors.firstWhere(
        (a) => WorkflowRun.phaseNameMatches(
            a.phaseName, participant['phase'] ?? ''),
        orElse: () => const WorkflowRunActor({}),
      ),
    );
    // Capture as final: the onTap closure can't read mutable locals'
    // promoted types.
    final resolvedActor = actor;
    final sessionId = resolvedActor.sessionId;
    final tappable = widget.onOpenActor != null && sessionId.isNotEmpty;

    return InkWell(
      borderRadius: BorderRadius.circular(kPillHeight / 2),
      onTap: tappable
          ? () => widget.onOpenActor!(sessionId, resolvedActor.name)
          : null,
      child: Container(
        height: kPillHeight,
        padding: const EdgeInsets.fromLTRB(8, 0, 10, 0),
        decoration: BoxDecoration(
          color: ZInk.codeBlockBg(context),
          borderRadius: BorderRadius.circular(kPillHeight / 2),
          border: Border.all(color: ZInk.hairline(context)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AgentFace(
              name: name,
              color: agentColor(name),
              expression: switch (mark) {
                _PillMark.running => FaceExpression.scanning,
                _PillMark.done => FaceExpression.happy,
                _PillMark.failed => FaceExpression.sad,
                _PillMark.none => FaceExpression.waiting,
              },
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: mark == _PillMark.none
                      ? ZInk.muted(context)
                      : ZInk.solid(context),
                ),
              ),
            ),
            if (mark == _PillMark.running)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              )
            else if (mark == _PillMark.done)
              Icon(Icons.check_circle_outline,
                  size: 14, color: ZInk.muted(context))
            else if (mark == _PillMark.failed)
              Icon(Icons.error_outline, size: 14, color: ZColors.danger),
          ],
        ),
      ),
    );
  }

  Widget _artifactStrip(BuildContext context, List<Map<String, dynamic>> artifacts) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final artifact in artifacts.take(3))
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: ZInk.codeBlockBg(context),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: ZInk.hairline(context)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_artifactIcon('${artifact['kind'] ?? ''}'),
                    size: 12, color: ZInk.muted(context)),
                const SizedBox(width: 4),
                Text(
                  '${artifact['title'] ?? artifact['kind'] ?? ''}',
                  style:
                      TextStyle(fontSize: 11.5, color: ZInk.soft(context)),
                ),
              ],
            ),
          ),
        if (artifacts.length > 3)
          Text(
            trP(context, 'chat.workflow.card.artifactsMore',
                ['${artifacts.length - 3}']),
            style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
          ),
      ],
    );
  }
}

/// Generic tool tile lives in tool_call_tile.dart; the workflow card needs
/// the same pretty-printed JSON block for the script/output folds.
Widget _kvBlock(BuildContext context, String label, String value) {
  var display = value;
  try {
    final decoded = jsonDecode(value);
    display = const JsonEncoder.withIndent('  ').convert(decoded);
  } catch (_) {}
  return Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 10.5, color: ZInk.faint(context)),
        ),
        const SizedBox(height: 2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: ZInk.codeBlockBg(context),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            display.length > 4000 ? '${display.substring(0, 4000)}…' : display,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: ZInk.solid(context),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Parsed CreateWorkflow display payload (official
/// create-workflow-display schema).
class _WorkflowDisplay {
  final bool ok;
  final int errorCount;
  final List<Map> diagnostics;
  final Map? graph;

  const _WorkflowDisplay({
    required this.ok,
    required this.errorCount,
    required this.diagnostics,
    required this.graph,
  });

  static _WorkflowDisplay? from(Map? display) {
    if (display == null || display['kind'] != 'create_workflow') return null;
    final graph = display['causalityGraph'];
    return _WorkflowDisplay(
      ok: display['ok'] == true,
      errorCount: (display['errorCount'] as num?)?.toInt() ?? 0,
      diagnostics: [
        if (display['diagnostics'] is List)
          for (final d in display['diagnostics'] as List)
            if (d is Map) d.cast<String, dynamic>(),
      ],
      graph: graph is Map ? graph : null,
    );
  }
}

enum _StationState { pending, running, done, failed }

class _StationInfo {
  final String key;
  final String name;
  const _StationInfo({required this.key, required this.name});
}

/// Station column: rail lamp on the shared horizontal line (10px, the
/// MARK_X spine), phase caption, participant pills stacked vertically.
class _StationColumn extends StatelessWidget {
  final _StationInfo station;
  final _StationState state;
  final List<Widget> pills;
  final bool isLast;

  const _StationColumn({
    required this.station,
    required this.state,
    required this.pills,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final (fill, border, labelColor) = switch (state) {
      _StationState.running => (
          ZColors.warning,
          ZColors.warning,
          ZColors.warning,
        ),
      _StationState.done => (
          ZColors.success,
          ZColors.success,
          ZInk.muted(context),
        ),
      _StationState.failed => (
          ZColors.danger,
          ZColors.danger,
          ZColors.danger,
        ),
      _ => (
          Colors.transparent,
          ZInk.faint(context),
          ZInk.muted(context),
        ),
    };
    return SizedBox(
      width: kStationWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Rail row: full-width hairline with the lamp on the MARK_X spine;
          // the last station trims the rail right after its lamp.
          SizedBox(
            height: kRailRowHeight,
            child: Stack(
              children: [
                Positioned(
                  top: kRailRowHeight / 2 - 0.8,
                  left: 0,
                  right: isLast ? kStationWidth - kLampCenterX : 0,
                  height: 1.6,
                  child: Container(color: ZInk.hairline(context)),
                ),
                Positioned(
                  left: kLampCenterX - kLampSize / 2,
                  top: kRailRowHeight / 2 - kLampSize / 2,
                  child: state == _StationState.running
                      ? _BeatLamp(size: kLampSize, color: fill)
                      : Container(
                          width: kLampSize,
                          height: kLampSize,
                          decoration: BoxDecoration(
                            color: fill,
                            shape: BoxShape.circle,
                            border: Border.all(color: border, width: 1.6),
                          ),
                          child: state == _StationState.done
                              ? Icon(
                                  Icons.check,
                                  size: 8,
                                  color: Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? const Color(0xFF101012)
                                      : Colors.white,
                                )
                              : null,
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: kCaptionX - 12 + 2),
            child: Text(
              station.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: labelColor),
            ),
          ),
          const SizedBox(height: 5),
          if (pills.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Text(
                tr(context, 'chat.workflow.card.noAgents'),
                style: TextStyle(fontSize: 11, color: ZInk.ghost(context)),
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final pill in pills)
                  Padding(
                    padding: const EdgeInsets.only(bottom: kPillGap),
                    child: pill,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

enum _PillMark { none, running, done, failed }

enum FaceExpression { waiting, scanning, happy, sad }

/// Agent tile face (web WorkflowAgentFace): a rounded square in one of the
/// nine fixed identity colors with two eyes; the eye shape reads the
/// status (waiting dots / scanning capsules / happy arcs / sad slants).
class AgentFace extends StatelessWidget {
  final String name;
  final Color color;
  final FaceExpression expression;

  const AgentFace({
    super.key,
    required this.name,
    required this.color,
    required this.expression,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final eyeColor = dark ? const Color(0xFF101012) : Colors.white;
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4.5),
      ),
      child: CustomPaint(
        painter: _FaceEyesPainter(
          eyeColor: eyeColor,
          expression: expression,
        ),
      ),
    );
  }
}

class _FaceEyesPainter extends CustomPainter {
  final Color eyeColor;
  final FaceExpression expression;

  _FaceEyesPainter({required this.eyeColor, required this.expression});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = eyeColor;
    final w = size.width;
    final h = size.height;
    switch (expression) {
      case FaceExpression.waiting:
        // Three dots (web `dots`, cx 5/10/15 cy 10 on the 20 grid).
        for (final fx in [0.25, 0.5, 0.75]) {
          canvas.drawCircle(Offset(w * fx, h * 0.5), 1.2, paint);
        }
      case FaceExpression.scanning:
        // Two vertical capsules (web `pill`, 4×6 rx2 at x 7/13 y 6).
        for (final fx in [0.35, 0.65]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(w * fx - w * 0.1, h * 0.3, w * 0.2, h * 0.32),
              const Radius.circular(1.6),
            ),
            paint,
          );
        }
      case FaceExpression.happy:
        // Happy arcs approximated by raised rounded rects (web happy path).
        for (final fx in [0.35, 0.65]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(w * fx - w * 0.1, h * 0.34, w * 0.2, h * 0.18),
              const Radius.circular(1.4),
            ),
            paint,
          );
        }
      case FaceExpression.sad:
        // Sad slants approximated by lowered tilted rects.
        for (final i in [0, 1]) {
          final fx = i == 0 ? 0.35 : 0.65;
          final dy = i == 0 ? 0.34 : 0.46;
          canvas.save();
          canvas.translate(w * fx, h * dy);
          canvas.rotate(i == 0 ? -0.35 : 0.35);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(-w * 0.1, 0, w * 0.2, h * 0.3),
              const Radius.circular(1.4),
            ),
            paint,
          );
          canvas.restore();
        }
    }
  }

  @override
  bool shouldRepaint(_FaceEyesPainter oldDelegate) =>
      eyeColor != oldDelegate.eyeColor ||
      expression != oldDelegate.expression;
}

/// Nine-color identity ring (web FACE_COLORS); name hash when the payload
/// carries no avatarIndex.
Color agentColor(String name) {
  const colors = [
    Color(0xFF54B9A6),
    Color(0xFFF19D38),
    Color(0xFF6464EF),
    Color(0xFF885CF5),
    Color(0xFF3C82F6),
    Color(0xFFED712E),
    Color(0xFFEB4699),
    Color(0xFF5BC67A),
    Color(0xFFEA4045),
  ];
  var hash = 0;
  for (final char in name.codeUnits) {
    hash = (hash * 31 + char) % 360;
  }
  return colors[hash % colors.length];
}

IconData _artifactIcon(String kind) => switch (kind) {
      'markdown' => Icons.description_outlined,
      'chart' => Icons.bar_chart_outlined,
      'table' => Icons.table_chart_outlined,
      'metrics' => Icons.query_stats_outlined,
      'board' => Icons.dashboard_outlined,
      _ => Icons.insert_drive_file_outlined,
    };

/// Run-lamp palette shared with the status panel rows (web
/// run-status-presentation): returns (fill, border, text color).
(Color, Color, Color) _workflowLamp(BuildContext context, String status,
    {required bool fallbackOk}) {
  return switch (status) {
    'running' => (
        ZColors.warning,
        ZColors.warning,
        ZColors.warning,
      ),
    'completed' => (
        ZColors.success,
        ZColors.success,
        ZColors.success,
      ),
    'errored' => (
        ZColors.danger,
        ZColors.danger,
        ZColors.danger,
      ),
    _ => (
        fallbackOk ? ZColors.success : Colors.transparent,
        fallbackOk ? ZColors.success : ZInk.faint(context),
        fallbackOk ? ZColors.success : ZInk.muted(context),
      ),
  };
}

/// Running-station lamp with the official heartbeat (web wf-beat 1.6s):
/// a soft warning halo swells and fades behind the steady lamp dot.
class _BeatLamp extends StatefulWidget {
  final double size;
  final Color color;

  const _BeatLamp({required this.size, required this.color});

  @override
  State<_BeatLamp> createState() => _BeatLampState();
}

class _BeatLampState extends State<_BeatLamp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Halo: swells past the dot while fading out, once per beat.
          FadeTransition(
            opacity: Tween(begin: 0.45, end: 0.0).animate(_controller),
            child: ScaleTransition(
              scale: Tween(begin: 1.0, end: 2.2).animate(_controller),
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.35),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}

/// Live kind word with the official sweep (web animated-gradient-text, 4s
/// linear loop): a soft band slides across the otherwise solid text.
class _SweepText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _SweepText({required this.text, required this.style});

  @override
  State<_SweepText> createState() => _SweepTextState();
}

class _SweepTextState extends State<_SweepText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4000),
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final strong = dark ? Colors.white : const Color(0xFF0A0A0A);
    final soft = (dark ? Colors.white : const Color(0xFF0A0A0A))
        .withValues(alpha: 0.2);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final dx = bounds.width * 2;
            return LinearGradient(
              begin: Alignment(-1 + 2 * t, 0),
              end: Alignment(1 + 2 * t, 0),
              colors: [strong, strong, soft, strong, strong],
              stops: const [0, 0.34, 0.5, 0.66, 1],
            ).createShader(
              Rect.fromLTWH(-dx / 2, 0, bounds.width + dx, bounds.height),
            );
          },
          child: child,
        );
      },
      child: Text(widget.text, style: widget.style),
    );
  }
}

/// Delayed entrance (web wf-arrive, 30ms stagger across the whole card).
class _Enter extends StatefulWidget {
  final int ordinal;
  final Widget child;

  const _Enter({required this.ordinal, required this.child});

  @override
  State<_Enter> createState() => _EnterState();
}

class _EnterState extends State<_Enter> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    _delay = Timer(Duration(milliseconds: widget.ordinal * 30), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.12),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut)),
        child: widget.child,
      ),
    );
  }
}
