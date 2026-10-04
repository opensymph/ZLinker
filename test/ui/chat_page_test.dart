import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/protocol/off_peak.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/ui/chat/chat_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

/// Recording fake: subscribes answer from a real [ConversationState] fed
/// by hand; every mutating call is captured for assertions.
class FakeChatGateway extends ChangeNotifier implements ChatGateway {
  @override
  DeviceStatus status = DeviceStatus.connected;
  @override
  bool kicked = false;
  @override
  String? error;

  /// Swappable (not final): the bridge-rebuild heal test swaps in a fresh
  /// state to mimic the session re-subscribing underneath the page.
  ConversationState state = ConversationState();
  final List<(String, List<Object?>)> calls = [];
  Object Function(String method)? failSubscribeWith;

  /// Hold subscribe open until the test completes it — lets the snapshot
  /// land AFTER the page rendered its not-ready spinner.
  Completer<ChatHandle>? subscribeGate;

  /// Extra snapshot fields merged into every feed (queue, interactions...).
  Map<String, dynamic> snapshotExtra = const {};

  void feedSnapshot(
    List<Map<String, dynamic>> rows, {
    int? firstRowId,
    int? totalCount,
  }) {
    state.applyFrame({
      'toSeq': state.seq + 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': 's1',
          'logEpoch': 'e1',
          'revision': 3,
          'rows': {
            'window': rows,
            'totalCount': totalCount ?? rows.length,
            'firstRowId': firstRowId,
          },
          ...snapshotExtra,
        },
      },
    }, onGap: () => fail('unexpected gap'));
  }

  @override
  Future<ChatHandle> subscribe(String sessionId) async {
    final fail = failSubscribeWith;
    if (fail != null) throw fail('subscribe');
    final handle = ChatHandle(state: state, close: () async {});
    final gate = subscribeGate;
    if (gate != null) await gate.future;
    // Read `state` again after the gate: a swap while gated must hand out
    // the NEW subscription, like the session-level heal does.
    return identical(handle.state, state)
        ? handle
        : ChatHandle(state: state, close: () async {});
  }

  dynamic _rec(String method, [List<Object?> args = const []]) {
    calls.add((method, args));
    return {'status': 'accepted'};
  }

  @override
  Future<WorkspacePrep> prepareWorkspace() async =>
      WorkspacePrep.fromMap(const {
        'configOptions': [
          {
            'id': 'model',
            'name': '模型',
            'currentValue': 'builtin/glm-5.2',
            'options': [
              {'value': 'builtin/glm-5.2', 'name': 'GLM-5.2'},
              {'value': 'builtin/glm-5.2-air', 'name': 'GLM-5.2 Air'},
            ],
          },
          {
            'id': 'thought_level',
            'name': '思考等级',
            'currentValue': 'enabled',
            'options': [
              {'value': 'enabled', 'name': '开启'},
              {'value': 'off', 'name': '关闭'},
            ],
          },
        ],
        'slashCommands': [
          {'name': 'compact', 'description': '压缩上下文'},
        ],
      });

  @override
  Future<List<SkillEntry>> skills() async => const [];

  @override
  String? get chatWorkspaceId => 'ws-1';
  @override
  String? get workspacePath => '/repo/app';
  @override
  String? get remoteUrl =>
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=demo';

  @override
  Future<void> reconnect() async => _rec('reconnect');

  @override
  Future<dynamic> renameTask(String sessionId, String title) async =>
      _rec('renameTask', [sessionId, title]);
  @override
  Future<dynamic> setTaskPinned(String sessionId, bool pinned) async =>
      _rec('setTaskPinned', [sessionId, pinned]);
  @override
  Future<dynamic> setTaskArchived(String sessionId, bool archived) async =>
      _rec('setTaskArchived', [sessionId, archived]);
  @override
  Future<dynamic> setTaskUnread(String sessionId, bool unread) async =>
      _rec('setTaskUnread', [sessionId, unread]);
  @override
  Future<dynamic> deleteTask(String sessionId) async =>
      _rec('deleteTask', [sessionId]);

  @override
  void sendViewState({String? taskId}) {}

  @override
  Future<dynamic> reorderQueueItem(
    String sessionId,
    String queueItemId,
    String? beforeQueueItemId,
  ) async => _rec('reorderQueueItem', [sessionId, queueItemId,
        beforeQueueItemId]);

  @override
  Future<dynamic> snoozeInteraction(String sessionId, String interactionId) =>
      _rec('snoozeInteraction', [sessionId, interactionId]);

  @override
  Future<dynamic> cancelBackgroundWork(String sessionId, String workId) =>
      Future.value(_rec('cancelBackgroundWork', [sessionId, workId]));

  @override
  Future<dynamic> deleteSession(String sessionId) =>
      _rec('deleteSession', [sessionId]);

  @override
  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async =>
      _rec('fileRewindPreview', [sessionId, target]);

  List<Map<String, dynamic>> mentionFilesResult = const [];
  List<Map<String, dynamic>> mentionSubagentsResult = const [];
  List<Map<String, dynamic>> mentionSkillsResult = const [];
  List<({String id, String title})> mentionSessionsResult = const [];

  @override
  Future<List<Map<String, dynamic>>> mentionFiles() async =>
      mentionFilesResult;

  @override
  Future<List<Map<String, dynamic>>> mentionSkills() async =>
      mentionSkillsResult;

  @override
  Future<List<Map<String, dynamic>>> mentionSubagents() async =>
      mentionSubagentsResult;

  @override
  List<({String id, String title})> mentionSessions() =>
      mentionSessionsResult;

  @override
  List<Map<String, dynamic>> mentionSkillsSync() => mentionSkillsResult;

  @override
  Future<String> createSession(
    String workspaceId, {
    String? firstText,
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic>? config,
  }) async {
    _rec('createSession', [workspaceId, firstText, config]);
    return 'new-s1';
  }

  @override
  Future<dynamic> sendText(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
  }) async => _rec('sendText', [sessionId, text, heldQueueDisposition]);

  @override
  Future<dynamic> sendGoalCommand(
    String sessionId,
    String text, {
    String? heldQueueDisposition,
  }) async => _rec('sendGoalCommand', [sessionId, text]);

  @override
  Future<dynamic> stop(String sessionId) async => _rec('stop', [sessionId]);
  @override
  Future<dynamic> compact(String sessionId) async =>
      _rec('compact', [sessionId]);
  @override
  Future<dynamic> pauseGoal(String sessionId) async =>
      _rec('pauseGoal', [sessionId]);
  @override
  Future<dynamic> resumeGoal(String sessionId) async =>
      _rec('resumeGoal', [sessionId]);

  @override
  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) async => _rec('switchModelConfig', [sessionId, provider, model, thought]);

  @override
  Future<dynamic> switchCollaborationMode(String sessionId, String mode) =>
      Future.value(_rec('switchCollaborationMode', [sessionId, mode]));

  @override
  Future<dynamic> setFollowupMode(String sessionId, String mode) async =>
      _rec('setFollowupMode', [sessionId, mode]);

  @override
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) =>
      Future.value(_rec('setAssistantFeedback', [sessionId, target, feedback]));

  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) => Future.value(
    _rec('resolveInteraction', [
      sessionId,
      interactionId,
      optionId,
      action,
      content,
    ]),
  );

  @override
  Future<dynamic> respondWorkspaceHookReview(
    String sessionId,
    Map payload,
    List<String> reviewItemIds,
  ) => Future.value(
    _rec('respondWorkspaceHookReview', [sessionId, payload, reviewItemIds]),
  );

  /// Fixture for the quota banner tests; null = desktop rejected the call.
  Map<String, dynamic>? usageEntitlementFixture;
  List<Map<String, dynamic>> runArtifactsFixture = const [];
  ({Uint8List bytes, String? mediaType})? runArtifactBytesFixture;

  /// Fixture for the composer model picker (model-selection view).
  List<OffPeakModelChoice> modelChoicesFixture = const [];

  @override
  Future<List<OffPeakModelChoice>> modelSelectionView() async =>
      modelChoicesFixture;
  int usageEntitlementCalls = 0;

  @override
  Future<Map<String, dynamic>?> usageEntitlement() async {
    usageEntitlementCalls++;
    return usageEntitlementFixture;
  }

  @override
  Future<dynamic> resumeWorkflowRun(String sessionId, String runId,
          {String? name}) =>
      Future.value(_rec('resumeWorkflowRun', [sessionId, runId, name]));

  @override
  Future<List<Map<String, dynamic>>> runArtifacts(
      String sessionId, String runId) async {
    calls.add(('runArtifacts', [sessionId, runId]));
    return runArtifactsFixture;
  }

  @override
  Future<List<Map<String, dynamic>>> runArtifactData(
      String sessionId, String runId, String artifactId) async {
    calls.add(('runArtifactData', [sessionId, runId, artifactId]));
    return const [];
  }

  @override
  Future<({Uint8List bytes, String? mediaType})?> runArtifactBytes(
      String sessionId, String runId, Map<String, dynamic> artifact) async {
    calls.add(('runArtifactBytes', [sessionId, runId, artifact]));
    return runArtifactBytesFixture;
  }

  @override
  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async => _rec('rowsRange', [sessionId, beforeRowId, limit]);

  @override
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async => {'ref': 'r1', 'fileName': fileName, 'mime': mime, 'bytes': 1};

  @override
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) async => (bytes: Uint8List(0), mediaType: 'application/octet-stream');

  @override
  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) async =>
      _rec('sendQueuedNow', [sessionId, queueItemId]);
  @override
  Future<dynamic> editQueueItem(
    String sessionId,
    String queueItemId,
    String newText,
  ) async => _rec('editQueueItem', [sessionId, queueItemId, newText]);
  @override
  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) async =>
      _rec('deleteQueueItem', [sessionId, queueItemId]);
  @override
  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) async =>
      _rec('setAutoDrain', [sessionId, autoDrain]);
  @override
  Future<dynamic> plans(String sessionId) async => _rec('plans', [sessionId]);
  @override
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async => _rec('fileChanges', [sessionId, target]);
  @override
  Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target) =>
      Future.value(_rec('retryTurn', [sessionId, target]));
  @override
  Future<dynamic> forkAssistant(
    String sessionId,
    Map<String, dynamic> target,
  ) => Future.value(_rec('forkAssistant', [sessionId, target]));
  @override
  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText,
  ) => Future.value(_rec('editUserQuery', [sessionId, target, newText]));
  @override
  Future<dynamic> applyFileRewind(
    String sessionId,
    Map<String, dynamic> target,
  ) => Future.value(_rec('applyFileRewind', [sessionId, target]));
}

Widget wrap(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  darkTheme: buildDarkTheme(),
  builder: (context, child) =>
      UiSettingsProvider(settings: UiSettings(), child: child!),
  home: child,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders user bubble, assistant markdown and turn footer', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: '修复登录')),
    );
    // subscribe resolves on the next microtask; feed before settle
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '已修复 **登录** 问题'},
      {
        'rowId': 3,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 65000,
        'fileChanges': {'files': 2, 'additions': 10, 'deletions': 3},
      },
    ]);
    await tester.pumpAndSettle();

    expect(find.text('帮我修复登录'), findsOneWidget);
    expect(find.textContaining('已修复'), findsOneWidget);
    expect(find.text('任务会话'), findsOneWidget); // app bar caption
    expect(find.text('修复登录'), findsOneWidget); // app bar title
    // turn footer: worked duration + phase pill
    expect(find.textContaining('已工作'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
  });

  testWidgets(
    'snapshot arriving after the spinner swaps the body in on its own',
    (tester) async {
      // Regression: the not-ready spinner branch sat OUTSIDE any state
      // listener, so a snapshot landing after the page built never removed
      // it (top capsule listened, the body didn't) — it hung until an
      // unrelated page setState.
      final gateway = FakeChatGateway()
        ..subscribeGate = Completer<ChatHandle>();
      await tester.pumpWidget(
        wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
      );
      await tester.pump(); // first build: subscribe still pending
      gateway.subscribeGate!
          .complete(ChatHandle(state: gateway.state, close: () async {}));
      await tester.pump(); // handle set, snapshot not yet applied
      expect(find.text('帮我修复登录'), findsNothing);

      // Snapshot lands with NO page-level setState — only notifyListeners.
      gateway.feedSnapshot([
        {'rowId': 1, 'kind': 'userInput', 'text': '帮我修复登录'},
        {'rowId': 2, 'kind': 'assistantText', 'text': '已修复'},
      ]);
      await tester.pumpAndSettle();

      expect(find.text('帮我修复登录'), findsOneWidget);
    },
  );

  testWidgets('subscription swapped underneath the page is followed', (
    tester,
  ) async {
    // Regression: the bridge-rebuild heal disposes the session's old
    // conversation subscription and re-subscribes at the session level, but
    // the mounted page kept its dead handle — the body froze on whatever it
    // built last (spinner or stale list). The page must follow the swap
    // when the session notifies.
    final gateway = FakeChatGateway()
      ..subscribeGate = Completer<ChatHandle>();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    await tester.pump(); // first build: subscribe still pending
    gateway.subscribeGate!
        .complete(ChatHandle(state: gateway.state, close: () async {}));
    await tester.pump(); // handle set on the old state, not ready
    expect(find.text('桥换后的新消息'), findsNothing);

    // Heal: fresh state takes over, gets the snapshot, session notifies.
    gateway.state = ConversationState();
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '桥换后的新消息'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '新会话已接上'},
    ]);
    gateway.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('桥换后的新消息'), findsOneWidget);
    expect(find.text('新会话已接上'), findsOneWidget);
  });

  testWidgets('tool call renders summary + expandable diff', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '改一下'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'Edit',
        'status': 'success',
        'input': {
          'filePath': 'lib/a.dart',
          'old_string': 'a',
          'new_string': 'b',
        },
        'inputText':
            '{"filePath": "lib/a.dart", "old_string": "a", "new_string": "b"}',
      },
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(find.textContaining('已写入'), findsOneWidget);
    expect(find.textContaining('lib/a.dart'), findsWidgets);

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('-a'), findsWidgets);
    expect(find.textContaining('+b'), findsWidgets);
  });

  testWidgets('permission interaction resolves through the gateway', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'i1',
          'payload': {
            'kind': 'permission',
            'toolName': 'Bash',
            'summary': 'rm -rf build',
            'options': [
              {'optionId': 'o1', 'kind': 'allowOnce'},
              {'optionId': 'o2', 'kind': 'deny'},
            ],
          },
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('权限请求'), findsOneWidget);
    expect(find.text('允许一次'), findsOneWidget);

    await tester.tap(find.text('允许一次'));
    await tester.pumpAndSettle();
    final call = gateway.calls
        .where((c) => c.$1 == 'resolveInteraction')
        .toList()
        .single;
    expect(call.$2[1], 'i1');
    expect(call.$2[2], 'o1');
  });

  Map<String, dynamic> planApprovalInteraction(String id) => {
      'interactionId': id,
      'payload': {
        'kind': 'userInput',
        'toolName': 'ExitPlanMode',
        'prompt': 'proceed?',
        'freeText': true,
        'input': {'plan': '# Plan\n- step 1'},
        'schema': {
          'interaction': 'plan_approval',
          'toolName': 'ExitPlanMode',
        },
        'questions': [
          {
            'question': 'proceed?',
            'header': 'Plan',
            'options': [
              {'value': 'approve', 'label': 'Approve'},
            ],
          },
        ],
      },
    };

  testWidgets('plan approval card approves with the official content shape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [planApprovalInteraction('plan1')],
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('计划确认'), findsOneWidget);
    expect(find.textContaining('step 1'), findsOneWidget);

    await tester.tap(find.text('批准并继续'));
    await tester.pumpAndSettle();
    final call = gateway.calls
        .where((c) => c.$1 == 'resolveInteraction')
        .toList()
        .single;
    expect(call.$2[1], 'plan1');
    expect(call.$2[3], 'accept');
    final content = call.$2[4] as Map;
    expect(content['answers'], {'proceed?': 'approve'});
    expect(content['answer'], 'approve');
  });

  testWidgets('plan approval decline with feedback sends the feedback answer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [planApprovalInteraction('plan2')],
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    final feedbackField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText != null && w.decoration!.hintText!.contains('反馈意见'),
    );
    await tester.enterText(feedbackField, '先补测试');
    await tester.pump();
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    final call = gateway.calls
        .where((c) => c.$1 == 'resolveInteraction')
        .toList()
        .single;
    expect(call.$2[3], 'accept');
    final content = call.$2[4] as Map;
    expect(content['answers'], {'proceed?': '先补测试'});
  });

  testWidgets('elicitation form submits the official answers content shape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'el1',
          'payload': {
            'kind': 'userInput',
            'prompt': 'pick',
            'questions': [
              {
                'question': 'Q1',
                'options': [
                  {'value': 'a', 'label': 'A'},
                  {'value': 'b', 'label': 'B'},
                ],
              },
              {
                'question': 'Q2',
                'multiSelect': true,
                'options': [
                  {'value': 'x', 'label': 'X'},
                ],
              },
            ],
          },
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.tap(find.text('X'));
    await tester.pump();
    await tester.tap(find.text('提交回答'));
    await tester.pumpAndSettle();
    final call = gateway.calls
        .where((c) => c.$1 == 'resolveInteraction')
        .toList()
        .single;
    expect(call.$2[1], 'el1');
    expect(call.$2[3], 'accept');
    final content = call.$2[4] as Map;
    expect(content['answers'], {'Q1': 'a', 'Q2': 'x'});
    expect(content['answer_0'], 'a');
    expect(content['answer_1'], ['x']);
    // The legacy single-question `answer` field only appears for 1-question
    // requests (web buildElicitationResponseContent).
    expect(content.containsKey('answer'), isFalse);
  });

  testWidgets('hook review card trusts the selected hooks', (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'pendingInteractions': [
        {
          'interactionId': 'hk1',
          'payload': {
            'kind': 'workspaceHookReview',
            'workspaceLabel': 'repo',
            'items': [
              {
                'reviewItemId': 'h1',
                'displayName': 'Build hook',
                'displayCommand': 'make build',
                'event': 'SessionStart',
              },
              {
                'reviewItemId': 'h2',
                'displayName': 'Audit hook',
                'displayCommand': 'audit.sh',
                'event': 'Stop',
              },
            ],
          },
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Build hook'), findsOneWidget);
    // Uncheck the second hook, then trust only the first.
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    await tester.tap(find.text('信任所选 Hooks'));
    await tester.pumpAndSettle();
    final call = gateway.calls
        .where((c) => c.$1 == 'respondWorkspaceHookReview')
        .toList()
        .single;
    expect(call.$2[0], 's1');
    expect(call.$2[2], ['h1']);
  });

  testWidgets('status panel shows workflow rows and running bash works', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'workflowRuns': {
        'runs': [
          {
            'runId': 'wf1',
            'workId': 'wf1',
            'status': 'running',
            'nodesSettled': 2,
            'nodesTotal': 5,
            'title': 'wf1',
          },
        ],
      },
      'backgroundWorks': [
        {
          'workId': 'wf1',
          'kind': 'workflow',
          'status': 'running',
          'title': 'wf1',
          'cancellable': true,
        },
        {
          'workId': 'b1',
          'kind': 'bash',
          'status': 'running',
          'title': 'flutter test',
        },
      ],
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    // Fixed pumps: the workflow row's spinner never settles.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    // The panel starts as the compact capsule (web StatusSummaryRow):
    // backgroundWork counts only, no section rows.
    expect(find.text('工作流脚本'), findsNothing);
    expect(find.textContaining('个后台运行'), findsOneWidget);

    // Tap the capsule → full sections card (sections collapsed by default,
    // web StatusSection defaultOpen false) → then expand both sections.
    await tester.tap(find.textContaining('个后台运行'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('工作流'), findsOneWidget);
    expect(find.text('终端'), findsOneWidget);
    await tester.tap(find.text('工作流'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('终端'));
    await tester.pump(const Duration(milliseconds: 100));
    // title ≡ workId renders the unnamed fallback; steps come from the run.
    expect(find.text('工作流脚本'), findsOneWidget);
    expect(find.textContaining('2/5 步'), findsOneWidget);
    expect(find.text('flutter test'), findsOneWidget);

    // Cancel the bash row (last close button in the panel).
    await tester.tap(find.byTooltip('取消此后台任务').last);
    await tester.pump(const Duration(milliseconds: 100));
    final call = gateway.calls
        .where((c) => c.$1 == 'cancelBackgroundWork')
        .toList()
        .single;
    expect(call.$2, ['s1', 'b1']);
  });

  testWidgets('in-chat search finds turns and the rail renders', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hello one'},
      {'rowId': 2, 'kind': 'assistantText', 'text': 'reply one'},
      {'rowId': 3, 'kind': 'userInput', 'text': 'needle here'},
      {'rowId': 4, 'kind': 'assistantText', 'text': 'reply two'},
      {'rowId': 5, 'kind': 'userInput', 'text': 'three'},
      {'rowId': 6, 'kind': 'assistantText', 'text': 'needle again'},
      {'rowId': 7, 'kind': 'userInput', 'text': 'four'},
      {'rowId': 8, 'kind': 'assistantText', 'text': 'reply four'},
    ]);
    await tester.pumpAndSettle();

    // 4 turn groups → the navigator rail renders.
    expect(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == 'TurnNavigatorRail',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    final searchField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '搜索消息',
    );
    await tester.enterText(searchField, 'needle');
    // Debounced reindex (250ms).
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find.byTooltip('下一个'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('2/2'), findsOneWidget);

    // Closing resets the counter.
    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsNothing);
  });

  testWidgets('export sheet offers copy and save for the markdown dump', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: '导出任务')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hello world'},
      {'rowId': 2, 'kind': 'assistantText', 'text': 'hi there'},
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'Bash',
        'status': 'success',
        'inputText': '{}',
      },
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出 Markdown'));
    await tester.pumpAndSettle();

    expect(find.text('复制全文'), findsOneWidget);
    expect(find.text('保存为 .md 文件'), findsOneWidget);

    await tester.tap(find.text('复制全文'));
    await tester.pumpAndSettle();
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('composer draft restores from shared preferences', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'chat.draft.s1': '待发送草稿'});
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('待发送草稿'), findsOneWidget);
  });

  testWidgets('empty input history shows a hint toast', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('输入历史'));
    await tester.pumpAndSettle();
    expect(find.text('暂无输入历史'), findsOneWidget);
  });

  testWidgets('workflow card renders the causality graph and joins the live '
      'run', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'workflowRuns': {
        'runs': [
          {
            'runId': 'wf1',
            'workId': 'wf1',
            'status': 'running',
            'nodesSettled': 1,
            'nodesTotal': 3,
            'currentPhase': '巡检',
            'phaseNames': ['巡检', '汇总'],
          },
        ],
      },
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'toolName': 'CreateWorkflow',
        'status': 'success',
        'workId': 'wf1',
        'inputText': '{"name":"ci-patrol"}',
        'display': {
          'kind': 'create_workflow',
          'ok': true,
          'errorCount': 0,
          'diagnostics': [],
          'causalityGraph': {
            'steps': [
              {'id': 's1', 'label': 'a', 'phase': 'p1'},
              {'id': 's2', 'label': 'b', 'phase': 'p2'},
            ],
            'lanes': [
              {'id': 'l1', 'name': '巡检子代理'},
            ],
            'participants': [
              {'id': 'a1', 'phase': 'p1', 'lane': 'l1', 'steps': ['s1']},
              {'id': 'a2', 'phase': 'p2', 'lane': 'l1', 'steps': ['s2']},
            ],
            'phases': [
              {'id': 'p1', 'name': '巡检'},
              {'id': 'p2', 'name': '汇总'},
            ],
          },
        },
      },
    ]);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    // Status panel starts as the compact capsule (no section headers);
    // only the card kind word shows.
    expect(find.text('工作流'), findsOneWidget);
    expect(find.text('ci-patrol'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    // Vertical station columns: labels without counts; both stations on
    // the horizontal rail (汇总 = pending → hollow).
    expect(find.text('巡检'), findsOneWidget);
    expect(find.text('汇总'), findsOneWidget);
    // Participant pills: face tile + lane name; a1 is the running one.
    expect(find.text('巡检子代理'), findsNWidgets(2));
    // Header detail (web workflowCardDetail): phases · agents · working.
    // Steps intentionally never appear on the card.
    expect(find.textContaining('2 个阶段'), findsOneWidget);
    expect(find.textContaining('2 个子代理'), findsOneWidget);
    expect(find.textContaining('1/3 步'), findsNothing);
    // Current station lamp: 巡检 running (its pill spins, 汇总 pending).
    expect(find.text('汇总报告'), findsNothing);
  });

  testWidgets('automation, workflow and CUA tool cards render summaries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
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
        'toolName': 'CronCreate',
        'status': 'success',
        'inputText': '{}',
        'output': {
          'automationId': 'a1',
          'title': '每天站会提醒',
          'cronExpr': '0 9 * * 1-5',
        },
      },
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'CreateWorkflow',
        'status': 'success',
        'inputText': '{}',
      },
      {
        'rowId': 4,
        'kind': 'toolCall',
        'toolName': 'mcp__computer-use__computer-use',
        'status': 'success',
        'inputText': '{}',
        'display': {
          'kind': 'cua',
          'status': 'success',
          'toolName': 'screenshot',
        },
      },
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('定时任务 · 每天站会提醒'), findsOneWidget);
    expect(find.textContaining('0 9 * * 1-5'), findsOneWidget);
    expect(find.textContaining('工作流 · 已创建'), findsOneWidget);
    expect(find.textContaining('电脑操作 · 完成'), findsOneWidget);
  });

  testWidgets('quota banner shows model-quota states from the entitlement', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    gateway.usageEntitlementFixture = {
      'quota': {
        'limits': [
          {
            'meter': 'model_usage',
            'period': 'daily',
            'number': 100,
            'remaining': 5,
            'nextResetTime': 1790000000000,
          },
        ],
      },
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('模型额度不足 5%'), findsOneWidget);
    expect(gateway.usageEntitlementCalls, 1);

    // Dismiss works.
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();
    expect(find.textContaining('模型额度不足'), findsNothing);
  });

  testWidgets('quota banner stays silent when entitlement is unavailable', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();
    expect(find.textContaining('额度'), findsNothing);
  });

  testWidgets('draft mode shows tappable prompt suggestions', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: null, title: '新任务')),
    );
    await tester.pumpAndSettle();

    final suggestion = find.textContaining('总结这个项目');
    expect(suggestion, findsOneWidget);
    await tester.tap(suggestion);
    await tester.pumpAndSettle();
    // Picking fills the composer (and hides the suggestions with it).
    expect(find.widgetWithText(TextField, '总结这个项目的结构和入口'),
        findsOneWidget);
  });

  testWidgets('queue bar deletes a queued item', (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'queue': {
        'autoDrain': true,
        'items': [
          {'queueItemId': 'q1', 'text': '排队消息 A'},
        ],
      },
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('排队消息 1'), findsOneWidget);
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    // confirm dialog
    await tester.tap(find.text('删除').last);
    await tester.pump();
    final call = gateway.calls
        .where((c) => c.$1 == 'deleteQueueItem')
        .toList()
        .single;
    expect(call.$2, ['s1', 'q1']);
  });

  testWidgets('queue bar reorder issues reorderQueueItem with web shape',
      (tester) async {
    final gateway = FakeChatGateway();
    gateway.snapshotExtra = {
      'queue': {
        'autoDrain': true,
        'items': [
          {'queueItemId': 'q1', 'text': '排队消息 A'},
          {'queueItemId': 'q2', 'text': '排队消息 B'},
        ],
      },
    };
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    // move q2 up: it should be inserted before q1
    await tester.tap(find.byTooltip('上移').last);
    await tester.pump();
    final up = gateway.calls
        .where((c) => c.$1 == 'reorderQueueItem')
        .toList()
        .single;
    expect(up.$2, ['s1', 'q2', 'q1']);

    // move q1 down with nothing after q2 → beforeQueueItemId null (end)
    await tester.tap(find.byTooltip('下移').first);
    await tester.pump();
    final downs = gateway.calls
        .where((c) => c.$1 == 'reorderQueueItem')
        .toList();
    expect(downs.last.$2, ['s1', 'q1', null]);
  });

  testWidgets('@ trigger opens mention picker; picking inserts reference',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final gateway = FakeChatGateway();
    gateway.mentionFilesResult = [
      {
        'name': 'chat_page.dart',
        'relativePath': 'lib/ui/chat/chat_page.dart',
        'type': 'file',
      },
    ];
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '看一下 @');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // category list appears (ensure the tile is on-screen first).
    // Fixed pumps: the sheet's autofocus caret never lets pumpAndSettle
    // settle.
    expect(find.text('文件'), findsOneWidget);
    await tester.ensureVisible(find.text('文件'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('文件'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    expect(find.text('chat_page.dart'), findsOneWidget);
    await tester.tap(find.text('chat_page.dart'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }

    final tf = tester.widget<TextField>(find.byType(TextField).first);
    expect(tf.controller!.text, '看一下 @lib/ui/chat/chat_page.dart ');
  });

  testWidgets('draft mode: first send issues createSession with firstText', (
    tester,
  ) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(wrap(ChatPage(gateway: gateway, title: '新任务')));
    await tester.pumpAndSettle();
    expect(find.text('输入消息开始新任务'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '开始分析');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    // finite pumps: after createSession the page stays on the connect
    // spinner until the (fake) snapshot arrives, so pumpAndSettle hangs.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final call = gateway.calls
        .where((c) => c.$1 == 'createSession')
        .toList()
        .single;
    expect(call.$2[0], 'ws-1');
    expect(call.$2[1], '开始分析');
  });

  testWidgets('existing session: send goes through sendText', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '继续');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final call = gateway.calls.where((c) => c.$1 == 'sendText').toList().single;
    expect(call.$2, ['s1', '继续', null]);
  });

  testWidgets('kicked gateway shows the takeover overlay', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
    ]);
    await tester.pumpAndSettle();

    gateway.kicked = true;
    gateway.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('已被其他设备接管'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
  });

  testWidgets('subscribe failure surfaces the retry banner', (tester) async {
    final gateway = FakeChatGateway()
      ..failSubscribeWith = (m) => StateError('bridge down');
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    // finite pumps: the page shows an endless connect spinner on failure,
    // pumpAndSettle would time out on it. Pump through the full auto-retry
    // window (3 attempts, backoff 2s + 4s + 6s) so the banner is the final
    // state and no retry timer is left pending.
    await tester.pump();
    await tester.pump(const Duration(seconds: 14));
    expect(find.textContaining('订阅失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('reasoning rows collapse into the 思考过程 strip', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {'rowId': 2, 'kind': 'reasoning', 'text': '让我想想'},
      {'rowId': 3, 'kind': 'assistantText', 'text': '答案'},
    ]);
    await tester.pumpAndSettle();

    expect(find.text('思考过程'), findsOneWidget);
    // collapsed by default
    expect(find.text('让我想想'), findsNothing);
  });

  testWidgets('timeline markers render as centered capsules', (tester) async {
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {
        'rowId': 2,
        'kind': 'timelineMarker',
        'marker': {
          'type': 'modelChange',
          'fromModel': 'glm-5.2',
          'toModel': 'glm-5.2-air',
        },
      },
      {'rowId': 3, 'kind': 'assistantText', 'text': 'ok'},
    ]);
    await tester.pumpAndSettle();

    expect(find.textContaining('模型已切换 glm-5.2 → glm-5.2-air'), findsOneWidget);
  });

  testWidgets('user bubble hugs short text (no maxLines inflation)', (
    tester,
  ) async {
    // Regression: SelectableText(maxLines: 14) inflated short bubbles to
    // 14 lines inside the unbounded ListView; the bubble must hug content.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': '你好', 'state': 'done'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '回复', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(find.text('你好')).height, lessThan(30));
  });

  testWidgets('long user text collapses to 14 lines, 展开 reveals all', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    final longText = List.filled(30, '一行长文本内容').join('\n');
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': longText, 'state': 'done'},
      {'rowId': 2, 'kind': 'assistantText', 'text': '回复', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final bubbleText = find.textContaining('一行长文本内容');
    final clip = find.ancestor(
      of: bubbleText,
      matching: find.byType(SingleChildScrollView),
    );
    expect(clip, findsOneWidget);
    expect(tester.getSize(clip).height, lessThanOrEqualTo(14 * 21.0 + 1));

    await tester.tap(find.text('展开'));
    await tester.pump();
    expect(
      find.ancestor(
        of: bubbleText,
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    expect(tester.getSize(bubbleText).height, greaterThan(14 * 21.0));
  });

  testWidgets('send button disabled while the composer is empty', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    IconButton buttonOf() => tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byIcon(Icons.arrow_upward),
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(buttonOf().onPressed, isNull); // empty input → disabled

    await tester.enterText(find.byType(TextField), '继续');
    await tester.pump();
    expect(buttonOf().onPressed, isNotNull);
  });

  testWidgets('更多 menu: official order and pin toggle flips label', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final gateway = FakeChatGateway();
    await tester.pumpWidget(
      wrap(ChatPage(gateway: gateway, sessionId: 's1', title: 't')),
    );
    gateway.feedSnapshot([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi', 'state': 'done'},
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // Official web order: pin first, then rename / archive / unread,
    // then the copy actions.
    String itemText(PopupMenuItem<String> i) {
      final w = i.child;
      if (w is Text) return w.data ?? '';
      if (w is Row) {
        for (final c in w.children) {
          if (c is Text) return c.data ?? '';
        }
      }
      return '';
    }

    final texts = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .map(itemText)
        .toList();
    expect(texts.first, '置顶任务');
    expect(texts.indexOf('重命名任务'), lessThan(texts.indexOf('归档任务')));
    expect(texts.indexOf('归档任务'), lessThan(texts.indexOf('标记为未读')));
    expect(texts.indexOf('复制路径'), lessThan(texts.indexOf('复制会话 ID')));

    await tester.tap(find.text('置顶任务'));
    await tester.pumpAndSettle();
    final pin = gateway.calls
        .where((c) => c.$1 == 'setTaskPinned')
        .toList()
        .single;
    expect(pin.$2, ['s1', true]);

    // The label flips to the unpinned wording after toggling.
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('取消置顶任务'), findsOneWidget);
  });
}
