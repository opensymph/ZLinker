import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/workflow_runs.dart';

WorkflowRun run(Map<String, dynamic> extra) =>
    WorkflowRun({'runId': 'wf1', ...extra});

void main() {
  test('parses the run projection header fields', () {
    final r = run({
      'status': 'running',
      'toolCallId': 'tc1',
      'resumable': true,
      'usage': {'spentTokens': 1200, 'nodesUsed': 3},
      'currentPhase': '巡检',
      'phaseNames': ['巡检', '汇总'],
      'subagentModel': 'glm-5.2',
    });
    expect(r.status, 'running');
    expect(r.toolCallId, 'tc1');
    expect(r.resumable, isTrue);
    expect(r.spentTokens, 1200);
    expect(r.nodesUsed, 3);
    expect(r.currentPhase, '巡检');
    expect(r.phaseNames, ['巡检', '汇总']);
  });

  test('nodeStepStatus follows the official state machine', () {
    WorkflowStepStatus step(String phase, {String outcome = ''}) =>
        nodeStepStatus(WorkflowRunNode({
          'siteId': 1,
          'ordinal': 0,
          'phase': phase,
          if (outcome.isNotEmpty) 'outcome': outcome,
        }));
    expect(step('queued'), WorkflowStepStatus.pending);
    expect(step('dispatched'), WorkflowStepStatus.pending);
    expect(step('waiting'), WorkflowStepStatus.pending);
    expect(step('executing'), WorkflowStepStatus.running);
    expect(step('repairing'), WorkflowStepStatus.running);
    expect(step('nudged'), WorkflowStepStatus.running);
    expect(step('settled', outcome: 'ok'), WorkflowStepStatus.done);
    expect(step('settled', outcome: 'failed'), WorkflowStepStatus.failed);
    expect(step('settled', outcome: 'cancelled'), WorkflowStepStatus.failed);
  });

  test('aggregateStatuses mirrors the official priority rules', () {
    expect(aggregateStatuses(const []), isNull);
    expect(
      aggregateStatuses([
        WorkflowStepStatus.pending,
        WorkflowStepStatus.running,
        WorkflowStepStatus.failed,
      ]),
      WorkflowStepStatus.running,
    );
    expect(
      aggregateStatuses(
          [WorkflowStepStatus.pending, WorkflowStepStatus.done]),
      WorkflowStepStatus.running,
    );
    expect(
      aggregateStatuses(
          [WorkflowStepStatus.pending, WorkflowStepStatus.pending]),
      WorkflowStepStatus.pending,
    );
    expect(
      aggregateStatuses([WorkflowStepStatus.done, WorkflowStepStatus.done]),
      WorkflowStepStatus.done,
    );
    expect(
      aggregateStatuses(
          [WorkflowStepStatus.done, WorkflowStepStatus.failed]),
      WorkflowStepStatus.failed,
    );
  });

  test('actors and nodes bind through the siteId@ordinal keys', () {
    final r = run({
      'actors': [
        {
          'siteId': 2,
          'ordinal': 0,
          'name': '巡检子代理',
          'sessionId': 'sess-a',
          'status': 'running',
          'phaseName': '巡检',
        },
      ],
      'nodes': [
        {
          'siteId': 10,
          'ordinal': 0,
          'phase': 'executing',
          'actorSiteId': 2,
          'actorOrdinal': 0,
          'phaseName': '巡检',
        },
        {
          'siteId': 11,
          'ordinal': 0,
          'phase': 'settled',
          'outcome': 'ok',
          'actorSiteId': 2,
          'actorOrdinal': 0,
        },
      ],
    });
    final actor = r.actor(2, 0);
    expect(actor, isNotNull);
    expect(actor!.sessionId, 'sess-a');
    expect(actor.status, 'running');

    // Aggregate over the actor's nodes: executing + settled → running
    // (any running wins over failed/done).
    expect(actorStatus(r, 2, 0), WorkflowStepStatus.running);
  });

  test('enteredPhase matches with the 128-char prefix tolerance', () {
    final longName = 'a' * 200;
    final r = run({
      'phases': [
        {'name': longName, 'rounds': 2},
      ],
    });
    expect(r.enteredPhase(longName), isTrue);
    expect(r.enteredPhase('a' * 128), isTrue);
    expect(r.enteredPhase('不存在'), isFalse);
  });

  test('phaseRounds collects entry rounds by name', () {
    final r = run({
      'phases': [
        {'name': '巡检', 'rounds': 2},
        {'name': '汇总', 'rounds': 0},
      ],
    });
    expect(phaseRounds(r)['巡检'], 2);
    expect(phaseRounds(r)['汇总'], 0);
  });

  test('marchTarget resolves the running station on the track', () {
    expect(
      marchTarget(
        track: ['巡检', '汇总'],
        currentPhase: '汇总',
        runLive: true,
      ),
      1,
    );
    expect(
      marchTarget(
        track: ['巡检', '汇总'],
        currentPhase: '巡检',
        runLive: false,
      ),
      isNull,
    );
  });
}
