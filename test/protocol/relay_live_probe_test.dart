// Diagnostic tool: progress goes to stdout, deliberately not a logger.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/connection_params.dart';
import 'package:zlinker/state/device_session.dart';

/// LIVE probe against a real desktop via the relay (run on demand, never in
/// CI): walks every workspace/task the bootstrap reports, subscribes each
/// conversation and verifies the initial snapshot arrives (the
/// stuck-loading regression).
///
/// flutter test test/protocol/relay_live_probe_test.dart \
///   --dart-define=PROBE_URL='https://zcode.z.ai/remote/v4?sid=...'
const probeUrlEnv = String.fromEnvironment('PROBE_URL');

/// Also readable from a file — shell quoting of `&`-laden pairing URLs is
/// unreliable across platforms. Keep this file out of the default
/// `flutter test` path when you're done probing.
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
  test('live relay probe: subscribe every conversation', () async {
    expect(
      probeUrl,
      isNotEmpty,
      reason: 'pass --dart-define=PROBE_URL=<pairing url>',
    );
    final session = DeviceSession(
      deviceId: 'probe',
      params: RemoteConnectionParams.parse(probeUrl)!,
    );
    addTearDown(session.dispose);
    await session.connect();
    expect(session.status, DeviceStatus.connected,
        reason: 'relay pairing/handshake');

    // Wait for the bootstrap task list (relay pushes it after pairing).
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (session.relayTasks.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // The relay bootstrap lists every session twice — dedup before walking.
    final seen = <String>{};
    final tasks = session.relayTasks
        .where((t) => seen.add('${t['taskId']}'))
        .toList(growable: false);
    print('=== relay tasks (${tasks.length} unique of '
        '${session.relayTasks.length}):');

    // Walk every task: open its workspace bridge, subscribe, verify the
    // initial snapshot actually arrives (the stuck-loading regression).
    final results = <String>[];
    for (final t in tasks) {
      final sid = '${t['taskId']}';
      final wsKey = '${t['workspaceKey'] ?? ''}';
      final ws = session.workspaces.firstWhere(
        (w) => '${w['workspaceIdentity'] ?? w['workspacePath'] ?? ''}' == wsKey ||
            '${w['workspacePath'] ?? ''}' == wsKey,
        orElse: () => const {},
      );
      final sw = Stopwatch()..start();
      String outcome;
      try {
        if (ws.isNotEmpty && session.activeWorkspace == null ||
            (ws.isNotEmpty &&
                session.activeWorkspace != null &&
                (session.activeWorkspace!['workspacePath'] ?? '') !=
                    (ws['workspacePath'] ?? ''))) {
          await session.openWorkspace(ws, taskId: sid);
        }
        final handle = await session.subscribe(sid);
        final readyDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (!handle.state.ready && DateTime.now().isBefore(readyDeadline)) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
        outcome = handle.state.ready
            ? 'READY rows=${handle.state.rows.length} total=${handle.state.totalCount}'
            : 'NOT READY after 15s (subscribe acked, no snapshot)';
        await handle.close();
      } catch (e) {
        outcome = 'ERROR $e';
      }
      final line = '$sid [$wsKey] → $outcome (${sw.elapsedMilliseconds}ms)';
      print(line);
      results.add(line);
    }
    print('=== probe summary: '
        '${results.where((r) => r.contains('READY') && !r.contains('NOT')).length} '
        'READY / ${results.length} tasks');
    for (final r in results.where(
        (r) => r.contains('NOT READY') || r.contains('ERROR'))) {
      print(r);
    }
    expect(
      results.where((r) => r.contains('NOT READY') || r.contains('ERROR')),
      isEmpty,
      reason: 'every conversation must reach READY',
    );
  },
      skip: probeUrl.isEmpty ? 'no PROBE_URL' : false,
      timeout: const Timeout(Duration(minutes: 15)));
}
