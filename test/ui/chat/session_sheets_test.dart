import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/state/device_session.dart';
import 'package:zlinker/ui/chat/session_sheets.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

class _FakeGateway extends ChangeNotifier implements ChatGateway {
  final List<String> calls = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName.toString());
    return super.noSuchMethod(invocation);
  }
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: Scaffold(body: child),
    );

ConversationState stateWithPlan() {
  final state = ConversationState();
  state.applyFrame({
    'toSeq': 1,
    'payload': {
      'kind': 'snapshot',
      'snapshot': {
        'sessionId': 's1',
        'logEpoch': 'e1',
        'revision': 1,
        'rows': {
          'window': <Map<String, dynamic>>[
            {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
          ],
          'totalCount': 1,
          'firstRowId': 1,
        },
        'plan': {
          'items': [
            {'id': '1', 'content': '步骤一', 'status': 'completed'},
            {'id': '2', 'content': '步骤二', 'status': 'inProgress'},
          ],
          'updatedAt': 1,
        },
      },
    },
  }, onGap: () => fail('unexpected gap'));
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('extractPlanMarkdown follows the web fallback chain', () {
    expect(
      extractPlanMarkdown({
        'input': {'plan': '# A'},
      }),
      '# A',
    );
    expect(
      extractPlanMarkdown({
        'inputText': jsonEncode({'text': 'from inputText'}),
      }),
      'from inputText',
    );
    expect(
      extractPlanMarkdown({
        'output': {'content': 'from output'},
      }),
      'from output',
    );
    expect(
      extractPlanMarkdown({
        'raw': {
          'rawOutput': {'plan': 'from raw'},
        },
      }),
      'from raw',
    );
    expect(extractPlanMarkdown({'input': {}}), '');
  });

  test('planDirectoryTitle prefers the h1 then the first plain line', () {
    expect(planDirectoryTitle('# 标题\n正文'), '标题');
    expect(planDirectoryTitle('- 第一步\n- 第二步'), '第一步');
    expect(planDirectoryTitle('   \n'), isNull);
  });

  testWidgets('PlansSheet renders the snapshot plan and history rows', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(PlansSheet(
      state: stateWithPlan(),
      planRows: [
        {
          'rowId': 2,
          'toolName': 'ExitPlanMode',
          'inputText': jsonEncode({'plan': '# 重构方案\n- 第一步'}),
        },
      ],
    )));

    expect(find.text('当前计划'), findsOneWidget);
    expect(find.text('步骤一'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('重构方案'), findsOneWidget);

    await tester.tap(find.text('重构方案'));
    // Fixed pumps: the inProgress step's spinner never settles.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('第一步'), findsWidgets);
  });

  testWidgets('FileChangesSheet lists files with diffs and a rewind entry', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    await tester.pumpWidget(wrap(FileChangesSheet(
      changes: {
        'files': 1,
        'additions': 1,
        'deletions': 1,
        'state': 'active',
        'items': [
          {
            'path': 'lib/a.dart',
            'additions': 1,
            'deletions': 1,
            'writeCount': 1,
            'toolNames': ['Edit'],
            'patches': [
              {
                'oldStart': 1,
                'oldLines': 1,
                'newStart': 1,
                'newLines': 1,
                'lines': ['-old line', '+new line'],
              },
            ],
          },
        ],
      },
      gateway: gateway,
      sessionId: 's1',
      target: {'rowId': 1},
    )));

    expect(find.text('lib/a.dart'), findsOneWidget);
    expect(find.textContaining('已回退'), findsNothing);

    await tester.tap(find.text('lib/a.dart'));
    await tester.pumpAndSettle();
    expect(find.textContaining('+new line'), findsOneWidget);
    expect(find.textContaining('-old line'), findsOneWidget);
  });
}
