// Diagnostic tool: progress goes to stdout, deliberately not a logger.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/connection_params.dart';
import 'package:zlinker/state/device_session.dart';

/// Ready/plan invariant probe: subscribes conversations and logs every
/// state-notify's (ready, snapshot?, plan?, rows) timeline, flagging any
/// notify where the capsule data (plan/goal) is present while !ready —
/// the "capsule visible but body spinner persists" bug.
///
/// flutter test test/protocol/relay_ready_invariant_probe_test.dart \
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
  test('ready/plan invariant: capsule data never precedes ready', () async {
    expect(probeUrl, isNotEmpty,
        reason: 'pass --dart-define=PROBE_URL=<pairing url>');
    final session = DeviceSession(
      deviceId: 'probe',
      params: RemoteConnectionParams.parse(probeUrl)!,
    );
    addTearDown(session.dispose);
    await session.connect();
    expect(session.status, DeviceStatus.connected);

    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (session.relayTasks.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    final seen = <String>{};
    final tasks = session.relayTasks
        .where((t) => seen.add('${t['taskId']}'))
        .toList(growable: false);

    var violations = 0;
    for (final t in tasks) {
      final sid = '${t['taskId']}';
      final wsKey = '${t['workspaceKey'] ?? ''}';
      final ws = session.workspaces.firstWhere(
        (w) =>
            '${w['workspaceIdentity'] ?? w['workspacePath'] ?? ''}' == wsKey ||
            '${w['workspacePath'] ?? ''}' == wsKey,
        orElse: () => const {},
      );
      try {
        if (ws.isNotEmpty &&
            (session.activeWorkspace == null ||
                (session.activeWorkspace!['workspacePath'] ?? '') !=
                    (ws['workspacePath'] ?? ''))) {
          await session.openWorkspace(ws, taskId: sid);
        }
        final handle = await session.subscribe(sid);
        final states = <String>[];
        void snapshotState() {
          final s = handle.state;
          final capsuleData = s.plan != null || s.goal != null;
          states.add(
              'ready=${s.ready} snap=${s.snapshot != null} '
              'plan=${s.plan != null} rows=${s.rows.length}');
          if (capsuleData && !s.ready) violations++;
        }

        handle.state.addListener(snapshotState);
        // Initial timeline + one quiet beat for late frames.
        snapshotState();
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        snapshotState();
        print('$sid: ${states.join(" → ")}');
        await handle.close();
      } catch (e) {
        print('$sid: ERROR $e');
      }
    }
    print('=== invariant violations: $violations');
    expect(violations, 0, reason: 'plan/goal must never precede ready');
  },
      skip: probeUrl.isEmpty ? 'no PROBE_URL' : false,
      timeout: const Timeout(Duration(minutes: 20)));
}
