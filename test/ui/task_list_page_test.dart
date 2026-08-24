import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zremote/state/device_session.dart';
import 'package:zremote/state/device_store.dart';
import 'package:zremote/ui/chat/chat_page.dart';
import 'package:zremote/ui/task_list_page.dart';
import 'package:zremote/ui/theme.dart';
import 'package:zremote/ui/ui_settings.dart';

import '../helpers/fake_device_session.dart';

export '../helpers/fake_device_session.dart' show FakeDeviceSession;

Future<(DeviceStore, Device)> setupDevice() async {
  SharedPreferences.setMockInitialValues({});
  final store = DeviceStore();
  await store.load();
  await store.addUrl(
      'https://zcode.z.ai/remote/v4?sid=abc&hash=xyz&t=123&mid=m1&name=songsong&app_version=3.8.1');
  return (store, store.devices.single);
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: child,
    );

/// Logical 390×844 phone viewport (below the 768 dual-pane breakpoint).
void usePhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
}

/// Logical 1280×900 desktop viewport (dual-pane layout).
void useDesktop(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders workspace card with tasks and phase pills',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录',
          'phase': 'running',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
        {
          'sessionId': 's2',
          'title': '写周报',
          'phase': 'completedSuccess',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app', 'workspaceIdentity': 'app-id'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    // finite pumps: the running pill's spinner never settles
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('当前设备上的工作区和任务'), findsOneWidget);
    expect(find.text('app'), findsWidgets); // workspace title from path
    expect(find.text('本地'), findsOneWidget);
    expect(find.text('/repo/app'), findsOneWidget);
    expect(find.text('修复登录'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('1 个工作区 · 2 个任务'), findsOneWidget);
  });

  testWidgets('tapping a task pushes the native ChatPage (no suspend)',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录',
          'phase': 'running',
          'lastActivityAt': 1,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    final hub = DeviceSessionHub(nativeListEnabled: () => true);
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: hub,
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('修复登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('任务会话'), findsOneWidget);
    expect(find.text('修复登录'), findsOneWidget); // chat app-bar title
  });

  testWidgets('＋ starts a draft ChatPage', (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('新建任务'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('新建任务'), findsWidgets); // title + tooltip
    expect(find.text('输入消息开始新任务'), findsOneWidget); // draft hint
  });

  testWidgets('empty workspace shows the empty hint', (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pumpAndSettle();
    expect(find.text('暂无任务'), findsOneWidget);
  });

  testWidgets('online connection banner is always visible', (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pumpAndSettle();
    expect(find.text('ZCode 远程控制'), findsOneWidget);
    expect(find.text('已连接到当前桌面窗口'), findsOneWidget);
    expect(find.textContaining('本次连接可以查看当前设备上已打开的项目'), findsOneWidget);
  });

  testWidgets('long-press a task row opens the action sheet', (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录',
          'phase': 'running',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.longPress(find.text('修复登录'));
    // finite pumps: the running pill's spinner never settles
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);
  });

  testWidgets('the latest running task row gets the official highlight',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '旧任务',
          'phase': 'completedSuccess',
          'lastActivityAt': now - 100000,
        },
        {
          'sessionId': 's2',
          'title': '正在跑',
          'phase': 'running',
          'lastActivityAt': now,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final row = tester.widget<InkWell>(find.ancestor(
      of: find.text('正在跑'),
      matching: find.byType(InkWell),
    ));
    final material = tester.widget<Material>(find.ancestor(
      of: find.text('正在跑'),
      matching: find.byType(Material),
    ).first);
    expect(material.color, Colors.white.withValues(alpha: 0.1));
    expect(row.onLongPress, isNotNull);

    final oldRow = tester.widget<Material>(find.ancestor(
      of: find.text('旧任务'),
      matching: find.byType(Material),
    ).first);
    expect(oldRow.color, Colors.transparent);
  });

  testWidgets('dual-pane at ≥768: IDE sidebar + divider, tap opens in pane',
      (tester) async {
    useDesktop(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: [
        {
          'sessionId': 's1',
          'title': '修复登录',
          'phase': 'completedSuccess',
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Official IDE sidebar chrome — not the mobile card list.
    expect(find.text('新建任务'), findsWidgets);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('选择左侧任务查看会话'), findsOneWidget);
    expect(find.text('当前设备上的工作区和任务'), findsNothing);

    await tester.tap(find.text('修复登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('任务会话'), findsOneWidget);
    final chatPage = tester.widget<ChatPage>(find.byType(ChatPage));
    expect(chatPage.embedded, isTrue);
    // Sidebar still visible side by side.
    expect(find.text('项目'), findsOneWidget);
  });

  testWidgets('single column below 768: official mobile header, no sidebar',
      (tester) async {
    usePhone(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pumpAndSettle();

    expect(find.text('ZCode 远程控制'), findsOneWidget);
    expect(find.text('已连接到当前桌面窗口'), findsOneWidget);
    expect(find.text('当前设备上的工作区和任务'), findsOneWidget);
    expect(find.text('项目'), findsNothing);
    expect(find.text('选择左侧任务查看会话'), findsNothing);
  });

  testWidgets('desktop search nav opens command palette and picks a slash',
      (tester) async {
    useDesktop(tester);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    expect(find.text('/compact'), findsOneWidget);
    await tester.tap(find.text('/compact'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('/compact'), findsWidgets);
  });

  testWidgets('767 stays single column, 768 goes dual-pane', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(767, 844);
    addTearDown(tester.view.reset);
    final (store, device) = await setupDevice();
    final session = FakeDeviceSession(
      deviceId: device.id,
      params: device.params!,
      entries: const [],
      workspaces: [
        {'workspacePath': '/repo/app'},
      ],
    );
    await tester.pumpWidget(wrap(TaskListPage(
      store: store,
      hub: DeviceSessionHub(nativeListEnabled: () => false),
      device: device,
      sessionOverride: session,
    )));
    await tester.pump();
    expect(find.text('项目'), findsNothing);

    tester.view.physicalSize = const Size(768, 844);
    await tester.pump();
    expect(find.text('项目'), findsOneWidget);
  });
}
