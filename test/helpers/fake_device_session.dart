import 'package:zremote/protocol/conversation.dart';
import 'package:zremote/state/device_session.dart';

/// DeviceSession subclass answering from local tables (never connects).
class FakeDeviceSession extends DeviceSession {
  @override
  DeviceStatus status;
  @override
  final SessionsIndexState sessions;

  FakeDeviceSession({
    required super.deviceId,
    required super.params,
    List<Map<String, dynamic>> entries = const [],
    List<Map<String, dynamic>> workspaces = const [],
  })  : status = DeviceStatus.connected,
        sessions = SessionsIndexState(),
        super() {
    sessions.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'workspaceId': 'ws-1',
          'sessions': entries,
        },
      },
    }, onGap: () {});
    _workspaces = workspaces;
    _active = workspaces.isEmpty ? null : workspaces.first;
  }

  late List<Map<String, dynamic>> _workspaces;
  Map<String, dynamic>? _active;

  @override
  List<Map<String, dynamic>> get workspaces => _workspaces;
  @override
  Map<String, dynamic>? get activeWorkspace => _active;

  @override
  Future<void> reloadTasks() async {}

  @override
  Future<void> openWorkspace(Map<String, dynamic> workspace) async {
    _active = workspace;
    notifyListeners();
  }

  @override
  Future<ChatHandle> subscribe(String sessionId) async =>
      ChatHandle(state: ConversationState(), close: () async {});

  @override
  Future<WorkspacePrep> prepareWorkspace() async => WorkspacePrep.fromMap({
        'slashCommands': [
          {'name': 'compact', 'description': '压缩上下文', 'source': 'builtin'},
        ],
      });

  @override
  Future<List<SkillEntry>> skills() async => const [];

  @override
  String? get chatWorkspaceId => 'ws-1';
}
