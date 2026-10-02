import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zlinker/protocol/channel_client.dart';
import 'package:zlinker/protocol/off_peak.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/state/device_store.dart';
import 'package:zlinker/ui/off_peak_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

/// Fake off-peak device link answering from a local table.
class FakeOffPeakHost implements OffPeakHost {
  @override
  DeviceStatus status;

  final List<Map<String, dynamic>> tasks;
  final Map<String, dynamic> statusInfo;
  final List<(String, List<Object?>)> calls = [];
  Object Function(String method, List<Object?> args)? failWith;

  /// Fixture served by modelSelectionView (the official model-selection
  /// view); empty = desktop rejected the channel.
  List<OffPeakModelChoice> modelChoices = const [];

  FakeOffPeakHost(
    this.status, {
    this.tasks = const [],
    this.statusInfo = const {},
  });

  @override
  Map<String, dynamic> offPeakScope = const {
    'workspacePath': '/repo',
    'workspaceIdentity': 'repo-id',
  };

  @override
  late final OffPeakPort offPeak = OffPeakPort(_call);

  @override
  Future<List<OffPeakModelChoice>> modelSelectionView() async => modelChoices;

  Future<dynamic> _call(String method, List<Object?> args) async {
    final fail = failWith;
    if (fail != null) {
      throw fail(method, args);
    }
    calls.add((method, args));
    if (method.contains('list') || method.contains('List')) return tasks;
    if (method.startsWith('get') || method == 'status') return statusInfo;
    return null;
  }
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

Future<(DeviceStore, DeviceSessionHub)> setupDevice() async {
  SharedPreferences.setMockInitialValues({});
  final store = DeviceStore();
  await store.load();
  await store.addUrl(
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1');
  return (store, DeviceSessionHub(nativeListEnabled: () => false));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows tasks with queue badge and view-result button',
      (WidgetTester tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected, tasks: [
      {
        'offPeakTaskId': 't1',
        'title': 'CI 报告',
        'prompt': '分析 CI',
        'status': 'queued',
        'queuePosition': 2,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
      {
        'offPeakTaskId': 't2',
        'title': '文档检查',
        'prompt': '检查文档',
        'status': 'completed',
        'sessionId': 's-9',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'startedAt': DateTime.now().millisecondsSinceEpoch - 600000,
        'finishedAt': DateTime.now().millisecondsSinceEpoch,
      },
    ]);

    await tester.pumpWidget(wrap(OffPeakPage(
      store: store,
      hub: hub,
      device: store.devices.first,
      hostOverride: host,
    )));
    await tester.pumpAndSettle();

    // 设置 tab shows the active queue.
    expect(find.text('CI 报告'), findsOneWidget);
    expect(find.text('排队第 2 位'), findsOneWidget); // 排队位置徽标
    expect(find.text('等待闲时算力'), findsOneWidget);
    // 历史 tab holds the terminal runs.
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('文档检查'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('打开会话'), findsOneWidget);
    expect(find.textContaining('用时 10 分钟'), findsOneWidget);
  });

  testWidgets('quota header shows remaining + earliest window',
      (WidgetTester tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected, statusInfo: {
      'available': true,
      'quotaRemainingMinutes': 300,
      'earliestAvailableAt':
          DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch,
    });

    await tester.pumpWidget(wrap(OffPeakPage(
      store: store,
      hub: hub,
      device: store.devices.first,
      hostOverride: host,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('剩余额度'), findsOneWidget);
    expect(find.textContaining('5.0 小时'), findsOneWidget);
    expect(find.textContaining('最早可用'), findsOneWidget);
  });

  testWidgets('codingPlanOnly state shows the official error copy',
      (WidgetTester tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected, statusInfo: {
      'available': false,
      'reason': 'codingPlanOnly',
    });

    await tester.pumpWidget(wrap(OffPeakPage(
      store: store,
      hub: hub,
      device: store.devices.first,
      hostOverride: host,
    )));
    await tester.pumpAndSettle();

    expect(find.text('闲时任务仅向 Coding Plan 订阅用户开放'), findsOneWidget);
  });

  testWidgets('submit sheet prefills from a template and submits the wire shape',
      (WidgetTester tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected);

    await tester.pumpWidget(wrap(OffPeakPage(
      store: store,
      hub: hub,
      device: store.devices.first,
      hostOverride: host,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建闲时任务'));
    await tester.pumpAndSettle();

    // Template chip prefills title + prompt.
    await tester.tap(find.text('CI 失败与不稳定测试报告'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '扫描最近的 CI 运行，列出失败和不稳定测试及其可能原因，并按影响范围给出修复建议。'),
        findsOneWidget);

    await tester.ensureVisible(find.text('创建闲时任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建闲时任务'));
    await tester.pumpAndSettle();

    final submit = host.calls
        .where((c) => c.$1 == 'run' || c.$1 == 'submit')
        .toList();
    expect(submit, hasLength(1));
    final wire = submit.single.$2.single as Map<String, dynamic>;
    expect(wire['prompt'], '扫描最近的 CI 运行，列出失败和不稳定测试及其可能原因，并按影响范围给出修复建议。');
    expect(wire['workspacePath'], '/repo');
    expect(wire['workspaceIdentity'], 'repo-id');
    expect(wire['permissionMode'], 'build');
    expect(wire['offPeakTaskId'], isNotEmpty);
  });

  testWidgets('quota failure on submit shows the official error copy',
      (WidgetTester tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected);
    host.failWith = (m, _) =>
        ChannelRpcError('monthly off-peak quota exceeded', null);

    await tester.pumpWidget(wrap(OffPeakPage(
      store: store,
      hub: hub,
      device: store.devices.first,
      hostOverride: host,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建闲时任务'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, '任务指令'), '跑一次分析');
    // 完全访问 avoids the one-time full-access hint toast (it would queue
    // in front of the error snackbar).
    await tester.tap(find.text('权限模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完全访问').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('创建闲时任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建闲时任务'));
    await tester.pumpAndSettle();

    expect(find.text('闲时任务额度已用完，请稍后再试'), findsOneWidget);
    // Sheet stays open for correction / cancel (FAB + sheet title both say
    // 新建闲时任务).
    expect(find.text('新建闲时任务'), findsNWidgets(2));
  });

  testWidgets('paused runs show the #{position} badge', (tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected, tasks: [
      {
        'offPeakTaskId': 't1',
        'title': '暂停任务',
        'prompt': 'p',
        'status': 'paused',
        'queuePosition': 3,
      },
    ]);
    await tester.pumpWidget(wrap(OffPeakPage(
      store: store, hub: hub, device: store.devices.first, hostOverride: host,
    )));
    await tester.pumpAndSettle();

    expect(find.text('#3 已暂停'), findsOneWidget); // official paused badge
    expect(find.text('排队第 3 位'), findsNothing);
  });

  testWidgets('pause action shows the official queue hint',
      (tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected, tasks: [
      {
        'offPeakTaskId': 't1',
        'title': '运行中',
        'prompt': 'p',
        'status': 'running',
      },
    ]);
    await tester.pumpWidget(wrap(OffPeakPage(
      store: store, hub: hub, device: store.devices.first, hostOverride: host,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂停').last);
    await tester.pumpAndSettle();

    expect(host.calls.where((c) => c.$1 == 'pause'), hasLength(1));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('暂停时长超过队列等待时限的任务，将会被重新放回队列。'),
        findsOneWidget);
  });

  testWidgets('editing an existing run submits the desktop update shape',
      (tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected, tasks: [
      {
        'offPeakTaskId': 't9',
        'title': '旧指令',
        'prompt': '原始内容',
        'status': 'queued',
      },
    ]);
    await tester.pumpWidget(wrap(OffPeakPage(
      store: store, hub: hub, device: store.devices.first, hostOverride: host,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('编辑闲时任务'), findsOneWidget);
    // Prefilled from the stored run.
    expect(find.widgetWithText(TextField, '旧指令'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, '旧指令'), '改成的新标题');
    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final updates = host.calls.where((c) => c.$1 == 'updateTask').toList();
    expect(updates, hasLength(1));
    expect(updates.single.$2.single, {
      'offPeakTaskId': 't9',
      'title': '改成的新标题',
      'prompt': '原始内容',
      'permissionMode': 'build',
      'model': null,
      'thoughtLevel': null,
    });
  });

  testWidgets('history tab deletes records through deleteHistory',
      (tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected, tasks: [
      {
        'offPeakTaskId': 't2',
        'title': '已结束',
        'prompt': 'p',
        'status': 'completed',
      },
    ]);
    await tester.pumpWidget(wrap(OffPeakPage(
      store: store, hub: hub, device: store.devices.first, hostOverride: host,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除历史记录'));
    await tester.pumpAndSettle();
    // Confirm dialog.
    await tester.tap(find.text('删除历史记录').last);
    await tester.pumpAndSettle();

    expect(host.calls.where((c) => c.$1 == 'deleteHistory'), hasLength(1));
  });

  testWidgets('subscriber banner shows before the first task and dismisses',
      (tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected);
    await tester.pumpWidget(wrap(OffPeakPage(
      store: store, hub: hub, device: store.devices.first, hostOverride: host,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('订阅用户新功能体验'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.textContaining('订阅用户新功能体验'), findsNothing);
  });

  testWidgets('quota exhaustion shows the reset countdown line',
      (tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected, statusInfo: {
      'available': false,
      'reason': 'quota',
      'quotaResetRemainingMs':
          90 * 60 * 1000, // reads as seconds→fallback path keeps ms here
    });
    await tester.pumpWidget(wrap(OffPeakPage(
      store: store, hub: hub, device: store.devices.first, hostOverride: host,
    )));
    await tester.pumpAndSettle();

    expect(find.text('闲时任务额度已用完，请稍后再试'), findsOneWidget);
    expect(find.textContaining('可在1 小时 30 分钟后再次创建'), findsOneWidget);
  });

  testWidgets('pause and cancel route through the port',
      (WidgetTester tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected, tasks: [
      {
        'offPeakTaskId': 't1',
        'title': '排队任务',
        'prompt': 'p',
        'status': 'queued',
        'queuePosition': 1,
      },
    ]);

    await tester.pumpWidget(wrap(OffPeakPage(
      store: store,
      hub: hub,
      device: store.devices.first,
      hostOverride: host,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消任务'));
    await tester.pumpAndSettle();
    // official confirm dialog before cancelling
    await tester.tap(find.text('取消任务').last);
    await tester.pumpAndSettle();

    final cancel = host.calls.where((c) => c.$1 == 'cancel').toList();
    expect(cancel, hasLength(1));
    expect(cancel.single.$2, [
      {'offPeakTaskId': 't1'}
    ]);
  });

  testWidgets('model-selection choices back the picker and the wire carries '
      'modelSelection', (tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected);
    host.modelChoices = [
      const OffPeakModelChoice(
        providerId: 'builtin',
        modelId: 'glm-5.2',
        providerName: 'BigModel',
        name: 'GLM-5.2',
        reasoningLevels: ['high', 'low'],
      ),
      const OffPeakModelChoice(
        providerId: 'kimi',
        modelId: 'moonshot-v2',
        providerName: 'kimi',
        name: 'Moonshot',
      ),
    ];

    await tester.pumpWidget(wrap(OffPeakPage(
      store: store, hub: hub, device: store.devices.first, hostOverride: host,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建闲时任务'));
    await tester.pumpAndSettle();

    // Picker opens with the view's models (display name + provider).
    await tester.tap(find.text('GLM-5.2'));
    await tester.pumpAndSettle();
    expect(find.text('Moonshot'), findsOneWidget);
    expect(find.text('kimi'), findsOneWidget);

    // Switch to Moonshot and pick a reasoning level.
    await tester.tap(find.text('Moonshot'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, '任务指令'), '带模型选择的分析');
    await tester.ensureVisible(find.text('创建闲时任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建闲时任务'));
    await tester.pumpAndSettle();

    final submit = host.calls.where((c) => c.$1 == 'run' || c.$1 == 'submit');
    final wire = submit.single.$2.single as Map<String, dynamic>;
    expect(wire['modelSelection'], {
      'providerId': 'kimi',
      'modelId': 'moonshot-v2',
    });
    // Legacy fields dual-write the composite for older desktops.
    expect(wire['model'], 'kimi/moonshot-v2');
  });

  testWidgets('editing a run with a stored modelSelection restores and '
      'submits it', (tester) async {
    final (store, hub) = await setupDevice();
    final host = FakeOffPeakHost(DeviceStatus.connected, tasks: [
      {
        'offPeakTaskId': 't7',
        'title': '结构化任务',
        'prompt': '原始内容',
        'status': 'queued',
        'modelSelection': {
          'providerId': 'kimi',
          'modelId': 'moonshot-v2',
          'options': {'reasoningLevel': 'high'},
        },
      },
    ]);
    host.modelChoices = [
      const OffPeakModelChoice(
        providerId: 'kimi',
        modelId: 'moonshot-v2',
        providerName: 'kimi',
        name: 'Moonshot',
        reasoningLevels: ['high', 'low'],
      ),
    ];
    await tester.pumpWidget(wrap(OffPeakPage(
      store: store, hub: hub, device: store.devices.first, hostOverride: host,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    // Restored from the stored selection (display name, not the composite).
    expect(find.text('Moonshot'), findsWidgets);

    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final updates = host.calls.where((c) => c.$1 == 'updateTask').toList();
    expect(updates, hasLength(1));
    final wire = updates.single.$2.single as Map<String, dynamic>;
    expect(wire['modelSelection'], {
      'providerId': 'kimi',
      'modelId': 'moonshot-v2',
      'options': {'reasoningLevel': 'high'},
    });
    expect(wire['model'], 'kimi/moonshot-v2');
  });

  test('off-peak wire helpers parse and emit the official shapes', () {
    // View flattening: providers → choices with reasoning levels.
    final choices = parseModelSelectionView({
      'revision': 3,
      'providers': [
        {
          'providerId': 'builtin',
          'providerName': 'BigModel',
          'models': [
            {
              'modelId': 'glm-5.2',
              'config': {
                'name': 'GLM-5.2',
                'optionSpecs': {
                  'reasoningLevel': {'values': ['max', 'high', 'off']},
                },
              },
            },
            {'modelId': 'glm-5.2-air'},
          ],
        },
      ],
    });
    expect(choices, hasLength(2));
    expect(choices[0].composite, 'builtin/glm-5.2');
    expect(choices[0].name, 'GLM-5.2');
    expect(choices[0].reasoningLevels, ['max', 'high', 'off']);
    expect(choices[1].name, 'glm-5.2-air');

    // Wire: structured selection + legacy dual-write.
    final wire = OffPeakSubmitInput(
      prompt: 'p',
      workspacePath: '/repo',
      model: choices[0].composite,
      thoughtLevel: 'high',
      modelSelection: choices[0].selection(reasoningLevel: 'high'),
    ).toWire();
    expect(wire['modelSelection'], {
      'providerId': 'builtin',
      'modelId': 'glm-5.2',
      'options': {'reasoningLevel': 'high'},
    });
    expect(wire['model'], 'builtin/glm-5.2');
    expect(wire['thoughtLevel'], 'high');

    // Task parsing: stored selection + tolerant legacy fallback.
    final task = OffPeakTask({
      'offPeakTaskId': 't',
      'modelSelection': {
        'providerId': 'builtin',
        'modelId': 'glm-5.2',
        'options': {'reasoningLevel': 'off'},
      },
    });
    expect(task.modelSelection?.composite, 'builtin/glm-5.2');
    expect(task.modelSelection?.reasoningLevel, 'off');
    expect(OffPeakTask({'offPeakTaskId': 't2'}).modelSelection, isNull);
  });
}
