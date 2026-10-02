import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/ui/chat/chat_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

/// Adversarial fixtures for the workflow card: every messy-but-real shape
/// the desktop can project must render without throwing (a throw shows as
/// Flutter's red error widget in debug builds).
Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: Scaffold(body: child),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('stopped run with unknown stop reason and broken input', (
    tester,
  ) async {
    final gateway = _FakeGatewayWithRun({
      'runId': 'wf1',
      'workId': 'wf1',
      'toolCallId': 'tc1',
      'status': 'stopped',
      'stopReason': 'unknown_reason_value',
      'resumable': true,
      'currentPhase': '不存在的阶段',
      'phaseNames': ['只有一站'],
      // Real desktop shape: ids serialized as numeric STRINGS.
      'actors': [
        {'siteId': '0', 'ordinal': '0', 'status': 'waiting'},
      ],
      'nodes': [
        {'siteId': '5', 'ordinal': '0', 'phase': 'queued'},
      ],
      'artifacts': [
        {'id': 'a'},
      ],
    });
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {
        'rowId': 1,
        'kind': 'toolCall',
        'toolName': 'CreateWorkflow',
        'status': 'success',
        'workId': 'wf1',
        'toolCallId': 'tc1',
        'inputText': '这不是 JSON',
        'display': {
          'kind': 'create_workflow',
          'ok': false,
          'errorCount': 1,
          'diagnostics': [
            {'line': 3, 'column': 1, 'code': 1, 'message': 'boom'},
          ],
        },
      },
    ]);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    final exception = tester.takeException();
    expect(exception, isNull, reason: 'exception: $exception');
  });

  testWidgets('errored run with graph-less display and empty everything', (
    tester,
  ) async {
    final gateway = _FakeGatewayWithRun({
      'runId': 'wf2',
      'workId': 'wf2',
      'status': 'errored',
      'actors': [],
      'nodes': [],
    });
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {
        'rowId': 1,
        'kind': 'toolCall',
        'toolName': 'AmendWorkflow',
        'status': 'error',
        'workId': 'wf2',
        'inputText': '{"name":"x"}',
        'display': {'kind': 'create_workflow', 'ok': false, 'errorCount': 0},
      },
    ]);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    final exception = tester.takeException();
    expect(exception, isNull, reason: 'exception: $exception');
  });

  testWidgets('running run with many participants exercises roster paths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final participants = [
      for (var i = 0; i < 9; i++)
        {
          'id': 'a$i',
          'phase': 'p${i % 2}',
          'lane': 'lane-$i',
          'steps': ['${i + 1}'],
          if (i == 0) 'member': {'index': 0, 'of': 3},
        },
    ];
    final gateway = _FakeGatewayWithRun({
      'runId': 'wf3',
      'workId': 'wf3',
      'status': 'running',
      'currentPhase': 'p1',
      'phaseNames': ['p1', 'p2'],
      'actors': [
        for (var i = 0; i < 9; i++)
          {
            'siteId': i,
            'ordinal': 0,
            'name': 'agent-$i',
            'sessionId': 'sess-$i',
            'status': 'running',
            'phaseName': 'p${i % 2}',
          },
      ],
      'nodes': [
        for (var i = 0; i < 9; i++)
          {
            'siteId': '${i + 1}',
            'ordinal': 0,
            'phase': i == 8 ? 'executing' : 'settled',
            if (i != 8) 'outcome': 'ok',
            'actorSiteId': '$i',
            'actorOrdinal': 0,
            'phaseName': 'p${i % 2}',
          },
      ],
    });
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {
        'rowId': 1,
        'kind': 'userInput',
        'text': 'hi',
      },
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'CreateWorkflow',
        'status': 'running',
        'workId': 'wf3',
        'inputText': '{"name":"big"}',
        'display': {
          'kind': 'create_workflow',
          'ok': true,
          'errorCount': 0,
          'diagnostics': [],
          'causalityGraph': {
            'steps': [
              for (var i = 0; i < 9; i++)
                {
                  'id': '${i + 1}',
                  'label': 'step-$i',
                  'lane': 'lane-$i',
                  'phase': 'p${i % 2}',
                },
            ],
            'lanes': [
              for (var i = 0; i < 9; i++)
                {'id': 'lane-$i', 'name': '泳道 $i'},
            ],
            'participants': participants,
            'phases': [
              {'id': 'p1', 'name': '阶段一'},
              {'id': 'p2', 'name': '阶段二'},
            ],
          },
        },
      },
    ]);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    final exception = tester.takeException();
    expect(exception, isNull, reason: 'exception: $exception');
  });
}

/// Minimal ChatGateway fake whose only job is to serve one workflowRuns
/// snapshot (noSuchMethod covers the rest of the interface).
class _FakeGatewayWithRun extends ChangeNotifier implements ChatGateway {
  final Map<String, dynamic> run;

  _FakeGatewayWithRun(this.run);

  Map<String, dynamic> snapshotExtra = const {};
  ConversationState get state => _state;
  final ConversationState _state = ConversationState();

  @override
  DeviceStatus status = DeviceStatus.connected;
  @override
  bool kicked = false;
  @override
  String? error;
  @override
  String? get chatWorkspaceId => 'ws-1';
  @override
  String? get workspacePath => '/repo';
  @override
  String? get remoteUrl => null;

  @override
  Future<ChatHandle> subscribe(String sessionId) async =>
      ChatHandle(state: _state, close: () async {});

  @override
  Future<WorkspacePrep> prepareWorkspace() async =>
      WorkspacePrep.fromMap(const {});

  @override
  Future<List<SkillEntry>> skills() async => const [];

  @override
  Future<List<Map<String, dynamic>>> mentionFiles() async => const [];

  @override
  Future<List<Map<String, dynamic>>> mentionSkills() async => const [];

  @override
  Future<List<Map<String, dynamic>>> mentionSubagents() async => const [];

  @override
  List<Map<String, dynamic>> mentionSkillsSync() => const [];

  @override
  Future<Map<String, dynamic>?> usageEntitlement() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  void feedSnapshot(List<Map<String, dynamic>> rows) {
    _state.applyFrame({
      'toSeq': _state.seq + 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': 's1',
          'logEpoch': 'e1',
          'revision': 1,
          'rows': {'window': rows, 'totalCount': rows.length},
          'workflowRuns': {
            'runs': [run],
          },
          ...snapshotExtra,
        },
      },
    }, onGap: () {});
    notifyListeners();
  }
}
