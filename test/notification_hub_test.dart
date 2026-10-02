import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zlinker/notifications/notification_service.dart';
import 'package:zlinker/notifications/notify_rules.dart';
import 'package:zlinker/protocol/automation.dart';
import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/protocol/off_peak.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/state/notification_hub.dart';
import 'package:zlinker/ui/ui_settings.dart';

/// Records what the hub would have shown; plugin-backed members no-op.
class RecordingService implements NotificationService {
  @override
  bool isReady = true;
  final shown =
      <(NotifyChannel, int, String, String, Map<String, dynamic>)>[];

  @override
  Future<void> show(NotifyChannel channel, int id, String title,
      String body, Map<String, dynamic> payload) async {
    shown.add((channel, id, title, body, payload));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake device link with a real SessionsIndexState (snapshots applied in
/// place) plus table-backed automation / off-peak ports.
class FakeNotifiableSession extends ChangeNotifier
    implements NotifiableSession {
  @override
  final String deviceId;
  @override
  DeviceStatus status;
  @override
  Map<String, dynamic> offPeakScope = const {};

  @override
  Map<String, dynamic> get automationScope => const {'workspacePath': '/repo'};

  List<Map<String, dynamic>> automationItems = [];
  List<Map<String, dynamic>> offPeakTasks = [];

  @override
  late final AutomationPort automation =
      AutomationPort((m, a) async => automationItems);
  @override
  late final OffPeakPort offPeak =
      OffPeakPort((m, a) async => offPeakTasks);

  @override
  Future<List<OffPeakModelChoice>> modelSelectionView() async => const [];

  final SessionsIndexState _state = SessionsIndexState();

  FakeNotifiableSession(this.deviceId,
      {this.status = DeviceStatus.connected});

  @override
  SessionsIndexState? get sessions => _state;

  /// Applies a full snapshot (title/phase per session) and notifies.
  void setEntries(List<(String, String, String)> entries) {
    _state.applyFrame({
      'toSeq': (_state.seq + 1),
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessions': [
            for (final (id, title, phase) in entries)
              {'sessionId': id, 'title': title, 'phase': phase},
          ],
        },
      },
    }, onGap: () {});
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('taskCompletionEvents (pure rules)', () {
    test('fires once per running→terminal transition', () {
      final events = taskCompletionEvents(
        previousPhases: {'s1': 'running', 's2': 'running', 's3': 'draft'},
        sessions: [
          (sessionId: 's1', title: '修复登录', phase: 'completedSuccess'),
          (sessionId: 's2', title: '部署', phase: 'error'),
          (sessionId: 's3', title: '草稿任务', phase: 'completedSuccess'),
        ],
      );
      expect(events, hasLength(2));
      expect(events[0].failed, isFalse);
      expect(events[1].failed, isTrue);
    });

    test('re-running fires again; unchanged terminal stays silent', () {
      const sessions = [(sessionId: 's1', title: 't',
        phase: 'completedSuccess')];
      expect(
          taskCompletionEvents(
              previousPhases: {'s1': 'running'}, sessions: sessions),
          hasLength(1));
      expect(
          taskCompletionEvents(
              previousPhases: {'s1': 'completedSuccess'},
              sessions: sessions),
          isEmpty);
    });

    test('prewarming counts as running; empty title falls back to id', () {
      final events = taskCompletionEvents(
        previousPhases: {'s1': 'prewarming'},
        sessions: [(sessionId: 's1', title: '', phase: 'error')],
      );
      expect(events.single.title, 's1');
      expect(events.single.failed, isTrue);
    });
  });

  group('offPeakEvents (pure rules)', () {
    test('notifies on transitions only', () {
      var events = offPeakEvents(
        previousStatuses: {'t1': 'queued', 't2': 'running'},
        tasks: [
          OffPeakTask({'offPeakTaskId': 't1', 'status': 'completed'}),
          OffPeakTask({'offPeakTaskId': 't2', 'status': 'failed'}),
        ],
      );
      expect(events, hasLength(2));
      expect(events[0].failed, isFalse);
      expect(events[1].failed, isTrue);

      events = offPeakEvents(
        previousStatuses: {'t1': 'completed', 't2': 'failed'},
        tasks: [
          OffPeakTask({'offPeakTaskId': 't1', 'status': 'completed'}),
          OffPeakTask({'offPeakTaskId': 't2', 'status': 'failed'}),
        ],
      );
      expect(events, isEmpty);
    });

    test('first sight of already-finished history stays silent', () {
      final events = offPeakEvents(
        previousStatuses: {},
        tasks: [
          OffPeakTask({
            'offPeakTaskId': 't1',
            'status': 'completed',
            'finishedAt': 123,
          }),
        ],
      );
      expect(events, isEmpty);
    });
  });

  group('automationRunEvents (pure rules)', () {
    test('notifies when lastRunAt bumps, classifying failures', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final events = automationRunEvents(
        previousLastRunAt: {'a1': now - 100, 'a2': now - 100},
        items: [
          AutomationItem({
            'automationId': 'a1',
            'title': '日报',
            'lastRunAt': now,
            'lastResult': 'success'
          }),
          AutomationItem({
            'automationId': 'a2',
            'title': '备份',
            'lastRunAt': now,
            'lastResult': 'error'
          }),
        ],
      );
      expect(events, hasLength(2));
      expect(events[0].failed, isFalse);
      expect(events[1].failed, isTrue);
    });

    test('first sight of an old run stays silent', () {
      final old = DateTime.now()
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch;
      expect(
          automationRunEvents(
            previousLastRunAt: {},
            items: [AutomationItem({'automationId': 'a1', 'lastRunAt': old})],
          ),
          isEmpty);
    });
  });

  group('NotificationHub glue', () {
    late RecordingService service;
    late UiSettings ui;
    late NotificationHub hub;
    late FakeNotifiableSession session;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      service = RecordingService();
      ui = UiSettings();
      await ui.load();
      hub = NotificationHub(
          service: service, ui: ui, deviceLabelOf: (id) => 'my-device');
      session = FakeNotifiableSession('d1');
      hub.syncWith([session]);
    });

    test('task running→completed notifies with deep-link payload', () async {
      session.setEntries([('s1', '修复登录', 'running')]);
      expect(service.shown, isEmpty);
      session.setEntries([('s1', '修复登录', 'completedSuccess')]);

      expect(service.shown, hasLength(1));
      final (channel, _, title, body, payload) = service.shown.single;
      expect(channel, NotifyChannel.tasks);
      expect(title, '任务完成');
      expect(body, '修复登录');
      expect(payload, {
        'type': 'task',
        'deviceId': 'd1',
        'sessionId': 's1',
        'title': '修复登录',
      });
    });

    test('master switch off silences but keeps tracking', () async {
      ui.notificationsEnabled = false;
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'error')]);
      expect(service.shown, isEmpty);

      // Re-enable: the next NEW transition notifies, no replay.
      ui.notificationsEnabled = true;
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'completedSuccess')]);
      expect(service.shown, hasLength(1));
      expect(service.shown.single.$3, '任务完成');
    });

    test('channel switch off silences only that channel', () async {
      ui.notifyTasksEnabled = false;
      session.setEntries([('s1', 't', 'running')]);
      session.setEntries([('s1', 't', 'completedSuccess')]);
      expect(service.shown, isEmpty);
    });

    test('reconnect does not replay old off-peak completions', () async {
      session.offPeakTasks = [
        {'offPeakTaskId': 'op1', 'title': 'CI 报告', 'status': 'running'},
      ];
      await hub.pollOffPeakNow();
      session.offPeakTasks = [
        {'offPeakTaskId': 'op1', 'title': 'CI 报告', 'status': 'completed'},
      ];
      await hub.pollOffPeakNow();
      expect(service.shown, hasLength(1));

      // Session leaves the hub (WebView handover / relay flap) and comes
      // back: the same completed task must NOT notify again.
      hub.syncWith([]);
      hub.syncWith([session]);
      await hub.pollOffPeakNow();
      expect(service.shown, hasLength(1),
          reason: 'status cache survives reconnects');
    });

    test('cold-start first poll baselines existing completions silently',
        () async {
      session.offPeakTasks = [
        {'offPeakTaskId': 'op1', 'title': '旧任务', 'status': 'completed'},
      ];
      await hub.pollOffPeakNow();
      expect(service.shown, isEmpty);
    });

    test('off-peak poll notifies completion with session deep-link',
        () async {
      session.offPeakTasks = [
        {'offPeakTaskId': 'op1', 'title': 'CI 报告', 'status': 'queued'},
      ];
      await hub.pollOffPeakNow();
      expect(service.shown, isEmpty); // queued is not an event

      session.offPeakTasks = [
        {
          'offPeakTaskId': 'op1',
          'title': 'CI 报告',
          'status': 'completed',
          'sessionId': 's-77',
        },
      ];
      await hub.pollOffPeakNow();

      expect(service.shown, hasLength(1));
      final (channel, _, title, body, payload) = service.shown.single;
      expect(channel, NotifyChannel.offPeak);
      expect(title, '闲时任务完成');
      expect(body, 'CI 报告');
      expect(payload['sessionId'], 's-77');
      expect(payload['type'], 'offPeak');
    });

    test('automation poll notifies fresh runs', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      session.automationItems = [
        {'automationId': 'a1', 'title': '日报', 'lastRunAt': now},
      ];
      await hub.pollAutomationsNow();

      expect(service.shown, hasLength(1));
      final (channel, _, title, body, payload) = service.shown.single;
      expect(channel, NotifyChannel.automations);
      expect(title, '自动化触发成功');
      expect(body, '日报');
      expect(payload['type'], 'auto');

      // Second poll with no change: silent.
      await hub.pollAutomationsNow();
      expect(service.shown, hasLength(1));
    });

    test('untracking a removed device drops its history', () async {
      hub.syncWith(const []);
      expect(hub, isNotNull);
      // After untracking, polls have nothing to iterate.
      await hub.pollOffPeakNow();
      expect(service.shown, isEmpty);
    });
  });
}
