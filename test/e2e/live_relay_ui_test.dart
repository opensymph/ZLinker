// LIVE UI end-to-end: drives the REAL ChatPage widget tree against the REAL
// relay (real DeviceSession) — open conversation → body renders → send →
// reply arrives. Validates the stuck-spinner and send-take-effect fixes at
// the UI layer, which the protocol-level probes cannot see.
//
// Skipped unless build/probe_url.txt (or PROBE_URL) provides a pairing URL.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zlinker/protocol/connection_params.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/ui/chat/chat_page.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

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

/// The throwaway session the send probe created — follow-ups land there so
/// test traffic stays in one disposable thread.
const testSessionId = 'sess_57f09809-6ede-46a7-a184-994ef5339bf4';

void main() {
  testWidgets('live UI: open conversation, body renders, send takes effect',
      (tester) async {
    ChatHandle? handle;
    final session = DeviceSession(
      deviceId: 'e2e-ui',
      params: RemoteConnectionParams.parse(probeUrl)!,
    );
    addTearDown(session.dispose);

    SharedPreferences.setMockInitialValues(const {});

    await tester.runAsync(() async {
      await session.connect();
      expect(session.status, DeviceStatus.connected);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (session.relayTasks.isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
      expect(session.relayTasks, isNotEmpty);
      // Open the workspace the test session lives in (the first task's).
      final t = session.relayTasks.first;
      final wsKey = '${t['workspaceKey'] ?? ''}';
      final ws = session.workspaces.firstWhere(
        (w) =>
            '${w['workspaceIdentity'] ?? w['workspacePath'] ?? ''}' == wsKey ||
            '${w['workspacePath'] ?? ''}' == wsKey,
        orElse: () => session.workspaces.first,
      );
      await session.openWorkspace(ws);
      // Own handle on the SAME subscription the page will get (dedup) —
      // lets the final assertion read the rows the page is rendering.
      handle = await session.subscribe(testSessionId);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        builder: (context, child) =>
            UiSettingsProvider(settings: UiSettings(), child: child!),
        home: ChatPage(
          gateway: session,
          sessionId: testSessionId,
          title: 'e2e',
        ),
      ),
    );

    // The body must leave the spinner state ONCE the snapshot lands — the
    // ready→list transition listens to the state now. Previous turn content
    // (请只回复两个字: 收到) should render without any page-level setState.
    final rendered = await _waitFor(
      tester,
      () => find.textContaining('请只回复两个字').evaluate().isNotEmpty,
      const Duration(seconds: 30),
    );
    expect(rendered, isTrue,
        reason: 'conversation body must render once the snapshot arrives');

    // Send a follow-up through the REAL composer.
    final field = find.byType(TextField).first;
    await tester.enterText(field, '收到请只回复: ok');
    await tester.pump();
    final sendBtn = find.byIcon(Icons.arrow_upward);
    expect(sendBtn, findsOneWidget);
    await tester.tap(sendBtn);
    await tester.pump();

    // The user bubble must appear (send took effect).
    final sent = await _waitFor(
      tester,
      () => find.textContaining('收到请只回复: ok').evaluate().isNotEmpty,
      const Duration(seconds: 20),
    );
    expect(sent, isTrue, reason: 'sent message must appear in the timeline');

    // The turn should answer (queue/startNow routing both eventually produce
    // an assistant row).
    final replied = await _waitFor(
      tester,
      () {
        final rows = handle?.state.rows ?? const <Map<String, dynamic>>[];
        return rows.any((r) =>
            r['kind'] == 'assistantText' &&
            '${r['text'] ?? ''}'.contains('ok') &&
            '${r['text'] ?? ''}'.length < 20);
      },
      const Duration(seconds: 120),
    );
    expect(replied, isTrue, reason: 'assistant should answer the follow-up');
  },
      skip: probeUrl.isEmpty,
      timeout: const Timeout(Duration(minutes: 5)));
}

Future<bool> _waitFor(
  WidgetTester tester,
  bool Function() condition,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return true;
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 150)),
    );
  }
  return condition();
}
