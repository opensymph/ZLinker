// Diagnostic tool: progress goes to stdout, deliberately not a logger.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/connection_params.dart';
import 'package:zlinker/state/device_session.dart';

/// LIVE send probe: creates a throwaway session on the active workspace,
/// sends one trivial message, and verifies the turn actually runs (assistant
/// row grows / completes) — the "send doesn't take effect" regression path.
///
/// flutter test test/protocol/relay_send_probe_test.dart \
///   --dart-define=PROBE_URL='https://zcode.z.ai/remote/v4?sid=...'
const probeUrlEnv = String.fromEnvironment('PROBE_URL');

final probeUrl = probeUrlEnv.isNotEmpty
    ? probeUrlEnv
    : () {
        try {
          return File('build/probe_url.txt').readAsStringSync().trim();
        } catch (_) {
          return '';
        }
      }();

void main() {
  test('live send probe: create session → sendText → turn runs', () async {
    expect(probeUrl, isNotEmpty,
        reason: 'pass --dart-define=PROBE_URL=<pairing url>');
    final session = DeviceSession(
      deviceId: 'probe-send',
      params: RemoteConnectionParams.parse(probeUrl)!,
    );
    addTearDown(session.dispose);
    await session.connect();
    expect(session.status, DeviceStatus.connected);

    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (session.relayTasks.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // Open the workspace of the most recent task so chatWorkspaceId is set.
    final t = session.relayTasks.first;
    final wsKey = '${t['workspaceKey'] ?? ''}';
    final ws = session.workspaces.firstWhere(
      (w) =>
          '${w['workspaceIdentity'] ?? w['workspacePath'] ?? ''}' == wsKey ||
          '${w['workspacePath'] ?? ''}' == wsKey,
      orElse: () => session.workspaces.isNotEmpty ? session.workspaces.first : const {},
    );
    expect(ws, isNotEmpty, reason: 'at least one workspace');
    final sw = Stopwatch()..start();
    await session.openWorkspace(ws, taskId: null);
    print('=== workspace opened in ${sw.elapsedMilliseconds}ms');
    print('=== chatWorkspaceId: ${session.chatWorkspaceId}');

    // 1) create the session (measures runtime warm-up).
    sw.reset();
    final sid = await session.createSession(
      session.chatWorkspaceId!,
      firstText: null,
    );
    print('=== session created: $sid (${sw.elapsedMilliseconds}ms)');

    // 2) subscribe and watch the timeline while sending.
    final handle = await session.subscribe(sid);
    var assistantRows = 0;
    var lastRunId = '';
    handle.state.addListener(() {
      final s = handle.state;
      final assistants = s.rows.where((r) => r['kind'] == 'assistantText');
      final running = s.rows.where((r) => r['state'] == 'streaming').length;
      final newLast = '${s.snapshot?['currentRunId'] ?? ''}';
      if (assistants.length != assistantRows ||
          (newLast.isNotEmpty && newLast != lastRunId)) {
        assistantRows = assistants.length;
        lastRunId = newLast;
        print('[tl] rows=${s.rows.length} assistants=$assistantRows '
            'streaming=$running run=$lastRunId');
      }
    });

    // 3) send.
    sw.reset();
    final ack = await session.sendText(sid, '请只回复两个字: 收到');
    print('=== sendText ack (${sw.elapsedMilliseconds}ms): $ack');
    expect(ack, isA<Object>());

    // 4) wait for the turn to produce an assistant row (≤90s).
    final turnDeadline = DateTime.now().add(const Duration(seconds: 90));
    var assistantSeen = false;
    while (DateTime.now().isBefore(turnDeadline)) {
      final found = handle.state.rows.any((r) =>
          r['kind'] == 'assistantText' &&
          '${r['text'] ?? ''}'.trim().isNotEmpty);
      if (found) {
        assistantSeen = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    print('=== assistant row arrived: $assistantSeen');
    for (final r in handle.state.rows.take(10)) {
      final text = '${r['text'] ?? ''}'.trim();
      print('  row ${r['rowId']} ${r['kind']} '
          '${text.substring(0, text.length.clamp(0, 40))}');
    }
    await handle.close();
    expect(assistantSeen, isTrue,
        reason: 'sendText acked but the turn never produced a reply');
  },
      skip: probeUrl.isEmpty ? 'no PROBE_URL' : false,
      timeout: const Timeout(Duration(minutes: 6)));
}
