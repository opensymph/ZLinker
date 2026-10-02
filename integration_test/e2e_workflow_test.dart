// End-to-end verification of the chat-page parity features on a REAL
// device target: workflow status rows, tool cards, cancel background work,
// plan approval and in-chat search. The app is driven through the
// [FakeDeviceSession] seam — the only stubbed layer (the relay/bridge
// transport needs a paired desktop); everything above it is production
// code, and every gateway command the UI issues is recorded and asserted.
//
//   ZLINKER_SHOT_DIR=build/e2e flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/e2e_workflow_test.dart -d windows
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zlinker/state/device_store.dart';
import 'package:zlinker/ui/chat/chat_page.dart';
import 'package:zlinker/ui/chat/chat_panels.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

import '../test/helpers/fake_device_session.dart';

final _captureKey = GlobalKey();

Widget _wrap(Widget child, ThemeController theme, UiSettings ui) =>
    // The boundary wraps the WHOLE MaterialApp: modal sheets, dialogs and
    // popup menus render in the navigator's overlay, above `home`.
    RepaintBoundary(
      key: _captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        builder: (context, child) =>
            UiSettingsProvider(settings: ui, child: child!),
        home: child,
      ),
    );

/// Desktop rasterization of the app boundary (binding.takeScreenshot is
/// mobile-only), matching screenshots_test.dart.
Future<void> _capture(WidgetTester tester, String name) async {
  final boundary =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir =
      Directory(Platform.environment['ZLINKER_SHOT_DIR'] ?? 'build/e2e');
  await dir.create(recursive: true);
  await File('${dir.path}/$name.png')
      .writeAsBytes(data!.buffer.asUint8List());
  await tester.pump(const Duration(milliseconds: 100));
}

/// [FakeDeviceSession] plus gateway-call recording: the inherited
/// DeviceSession implementations route into the live conversation
/// transport, which this harness must not touch — so the commands under
/// test are overridden to record.
class _RecordingSession extends FakeDeviceSession {
  _RecordingSession({
    required super.deviceId,
    required super.params,
    super.entries,
    super.workspaces,
    super.chatRows,
    super.snapshotExtra,
  });

  final List<(String, List<Object?>)> gatewayCalls = [];

  @override
  Future<dynamic> cancelBackgroundWork(String sessionId, String workId) async {
    gatewayCalls.add(('cancelBackgroundWork', [sessionId, workId]));
    return {'status': 'accepted'};
  }

  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    gatewayCalls.add(('resolveInteraction', [
      sessionId,
      interactionId,
      action,
      content,
    ]));
    return {'status': 'accepted'};
  }

  @override
  Future<dynamic> respondWorkspaceHookReview(
    String sessionId,
    Map payload,
    List<String> reviewItemIds,
  ) async {
    gatewayCalls.add(('respondWorkspaceHookReview', [
      sessionId,
      payload['reviewFlowId'],
      reviewItemIds,
    ]));
    return {'status': 'accepted'};
  }
}

const _url =
    'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=E2E%20Host&app_version=3.14.4';

final _now = DateTime.now().millisecondsSinceEpoch;

final _sessions = [
  {
    'sessionId': 'wf_e2e',
    'title': '工作流 E2E 验证',
    'phase': 'running',
    'lastAssistantPreview': '工作流已启动…',
    'lastActivityAt': _now,
  },
];

final _workspaces = [
  {'workspacePath': '/Users/dev/ZLinker', 'workspaceIdentity': 'ZLinker'},
];

final _chatRows = [
  {'rowId': 1, 'kind': 'userInput', 'text': '帮我跑一遍 ci-patrol 工作流'},
  {
    'rowId': 2,
    'kind': 'assistantText',
    'text': '好的，正在启动工作流 **ci-patrol**，先跑测试再汇总。',
  },
  {
    'rowId': 3,
    'kind': 'toolCall',
    'toolName': 'CreateWorkflow',
    'status': 'success',
    'workId': 'wf1',
    'inputText': '{"name":"ci-patrol"}',
    'output': {'text': 'workflow wf1 started'},
    'display': {
      'kind': 'create_workflow',
      'ok': true,
      'errorCount': 0,
      'diagnostics': [],
      'causalityGraph': {
        'steps': [
          {'id': 's1', 'kind': 'world-read', 'label': '拉取 CI 记录', 'lane': 'l1', 'phase': 'p1'},
          {'id': 's2', 'kind': 'ask', 'label': '汇总失败项', 'lane': 'l1', 'phase': 'p1'},
          {'id': 's3', 'kind': 'ask', 'label': '生成报告', 'lane': 'l1', 'phase': 'p2'},
        ],
        'lanes': [
          {'id': 'l1', 'name': '巡检子代理'},
          {'id': 'l2', 'name': '汇总报告'},
        ],
        'participants': [
          {'id': 'a1', 'phase': 'p1', 'lane': 'l1', 'steps': ['s1', 's2']},
          {'id': 'a2', 'phase': 'p2', 'lane': 'l2', 'steps': ['s3']},
        ],
        'handoffs': [
          {'from': 'a1', 'to': 'a2'},
        ],
        'phases': [
          {'id': 'p1', 'name': '巡检'},
          {'id': 'p2', 'name': '汇总'},
        ],
        'phaseEdges': [
          {'from': 'p1', 'to': 'p2'},
        ],
      },
    },
  },
  {
    'rowId': 4,
    'kind': 'toolCall',
    'toolName': 'Bash',
    'status': 'success',
    'inputText': '{"command":"flutter test"}',
    'output': {'text': 'All tests passed!'},
  },
];

final _planApproval = {
  'interactionId': 'plan1',
  'payload': {
    'kind': 'userInput',
    'toolName': 'ExitPlanMode',
    'prompt': 'proceed?',
    'freeText': true,
    'input': {'plan': '# 巡检方案\n- 跑全量测试\n- 汇总报告'},
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

final _hookReview = {
  'interactionId': 'hook1',
  'payload': {
    'kind': 'workspaceHookReview',
    'workspaceLabel': 'ZLinker',
    'reviewFlowId': 'flow1',
    'items': [
      {
        'reviewItemId': 'h1',
        'displayName': '构建钩子',
        'displayCommand': 'make build',
        'event': 'SessionStart',
      },
    ],
  },
};

final _workflowSnapshotExtra = {
  'workflowRuns': {
    'runs': [
      {
        'runId': 'wf1',
        'workId': 'wf1',
        'status': 'running',
        'nodesSettled': 2,
        'nodesTotal': 5,
        'title': 'ci-patrol 巡检',
        'currentPhase': '汇总',
        'phaseNames': ['巡检', '汇总'],
        'cancellable': true,
        'usage': {'spentTokens': 4200, 'nodesUsed': 3},
        'actors': [
          {'siteId': 0, 'ordinal': 0, 'name': '巡检子代理', 'sessionId': 'actor-sess-1', 'status': 'completed', 'phaseName': '巡检'},
          {'siteId': 1, 'ordinal': 0, 'name': '汇总报告', 'status': 'running', 'phaseName': '汇总'},
        ],
        'nodes': [
          {'siteId': 1, 'ordinal': 0, 'phase': 'settled', 'outcome': 'ok', 'actorSiteId': 0, 'actorOrdinal': 0, 'phaseName': '巡检'},
          {'siteId': 2, 'ordinal': 0, 'phase': 'settled', 'outcome': 'ok', 'actorSiteId': 0, 'actorOrdinal': 0, 'phaseName': '巡检'},
          {'siteId': 3, 'ordinal': 0, 'phase': 'executing', 'actorSiteId': 1, 'actorOrdinal': 0, 'phaseName': '汇总'},
        ],
        'artifacts': [
          {'id': 'ar1', 'kind': 'markdown', 'title': '巡检报告', 'version': '1'},
        ],
      },
    ],
  },
  'backgroundWorks': [
    {
      'workId': 'wf1',
      'kind': 'workflow',
      'status': 'running',
      'title': 'ci-patrol 巡检',
      'cancellable': true,
    },
    {
      'workId': 'b1',
      'kind': 'bash',
      'status': 'running',
      'title': 'flutter test --coverage',
    },
  ],
};

void main() {
  testWidgets('chat page workflow e2e (status rows → tool cards → search)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController();
    final ui = UiSettings();
    final store = DeviceStore();
    await store.load();
    await store.addUrl(_url);
    final device = store.devices.first;

    final session = _RecordingSession(
      deviceId: device.id,
      params: device.params!,
      entries: _sessions,
      workspaces: _workspaces,
      chatRows: _chatRows,
      snapshotExtra: _workflowSnapshotExtra,
    );

    await tester.pumpWidget(_wrap(
      ChatPage(gateway: session, sessionId: 'wf_e2e', title: '工作流 E2E 验证'),
      theme,
      ui,
    ));
    await tester.pump(const Duration(milliseconds: 1500));

    // 1) Status panel: starts as the compact capsule (web
    // StatusSummaryRow) at the top of the conversation — tap it to expand
    // the sections card (sections collapsed by default), then expand both
    // for the run row + bash row.
    final capsule = find.textContaining('个后台运行');
    expect(capsule, findsOneWidget);
    await tester.tap(capsule);
    await tester.pump(const Duration(milliseconds: 200));
    final panelScope = find.descendant(
      of: find.byType(StatusPanel),
      matching: find.text('工作流'),
    );
    expect(panelScope, findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(StatusPanel),
        matching: find.text('终端'),
      ),
      findsOneWidget,
    );
    await tester.tap(panelScope);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.descendant(
      of: find.byType(StatusPanel),
      matching: find.text('终端'),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('ci-patrol 巡检'), findsOneWidget);
    expect(find.text('flutter test --coverage'), findsOneWidget);
    // Workflow card: kind word + script name; station columns on the
    // horizontal rail — 巡检 is the running station (its pill spins),
    // 汇总 pending (hollow node). Panel expanded → "2/5 步" ×2.
    expect(find.text('工作流'), findsNWidgets(2)); // card kind + section header
    expect(find.text('ci-patrol'), findsOneWidget);
    expect(find.text('巡检'), findsOneWidget);
    expect(find.text('汇总'), findsOneWidget);
    // Participant pills: a1 done (2 steps settled), a2 is the running one.
    expect(find.text('巡检子代理'), findsOneWidget);
    expect(find.text('汇总报告'), findsOneWidget);
    // The live step copy shows on the card header; the panel row may add
    // a second instance depending on scroll position.
    expect(find.textContaining('2/5 步'), findsAtLeastNWidgets(1));
    // Artifact strip from run.artifacts.
    expect(find.text('巡检报告'), findsOneWidget);
    await _capture(tester, 'e2e-1-workflow-status');

    // 2) Cancel the running bash work → recorded gateway command.
    await tester.tap(find.byTooltip('取消此后台任务').last);
    await tester.pump(const Duration(milliseconds: 300));
    final cancel = session.gatewayCalls.last;
    expect(cancel.$1, 'cancelBackgroundWork');
    expect(cancel.$2[1], 'b1');

    // 3) In-chat search over the loaded rows ('ci-patrol' hits the user
    // turn AND the assistant reply — two groups).
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '搜索消息',
      ),
      'ci-patrol',
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byTooltip('下一个'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('2/2'), findsOneWidget);
    await _capture(tester, 'e2e-2-search');
    await tester.tap(find.byTooltip('取消'));
    await tester.pump(const Duration(milliseconds: 300));

    session.dispose();
  });

  testWidgets('chat page plan approval + hook review e2e', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController();
    final ui = UiSettings();
    final store = DeviceStore();
    await store.load();
    await store.addUrl(_url);
    final device = store.devices.first;

    final session = _RecordingSession(
      deviceId: device.id,
      params: device.params!,
      entries: _sessions,
      workspaces: _workspaces,
      chatRows: _chatRows,
      snapshotExtra: {
        'pendingInteractions': [_planApproval, _hookReview],
      },
    );

    await tester.pumpWidget(_wrap(
      ChatPage(gateway: session, sessionId: 'wf_e2e', title: '工作流 E2E 验证'),
      theme,
      ui,
    ));
    await tester.pump(const Duration(milliseconds: 1500));

    // 1) Plan approval card with the plan markdown.
    expect(find.text('计划确认'), findsOneWidget);
    expect(find.textContaining('巡检方案'), findsWidgets);
    expect(find.textContaining('跑全量测试'), findsOneWidget);
    await _capture(tester, 'e2e-3-plan-approval');

    // 2) Approve → resolveInteraction accept with the approve answer.
    await tester.tap(find.text('批准并继续'));
    await tester.pump(const Duration(milliseconds: 300));
    final resolve = session.gatewayCalls
        .firstWhere((c) => c.$1 == 'resolveInteraction');
    expect(resolve.$2[0], 'wf_e2e');
    expect(resolve.$2[1], 'plan1');
    expect(resolve.$2[2], 'accept');
    final content = resolve.$2[3] as Map;
    expect(content['answers'], {'proceed?': 'approve'});
    expect(content['answer'], 'approve');

    // 3) Hook review card: trust the listed hook.
    expect(find.textContaining('工作区 Hook 审核'), findsOneWidget);
    expect(find.text('构建钩子'), findsOneWidget);
    await tester.tap(find.text('信任所选 Hooks'));
    await tester.pump(const Duration(milliseconds: 300));
    final hook = session.gatewayCalls
        .firstWhere((c) => c.$1 == 'respondWorkspaceHookReview');
    expect(hook.$2[0], 'wf_e2e');
    expect(hook.$2[1], 'flow1');
    expect(hook.$2[2], ['h1']);
    await _capture(tester, 'e2e-4-hook-review');

    session.dispose();
  });
}
