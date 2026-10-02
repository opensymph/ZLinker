import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/conversation.dart';
import 'package:zlinker/ui/chat/goal_panel.dart';

ConversationState _stateWith(Map<String, dynamic> snapshot) {
  final state = ConversationState();
  state.applyFrame({
    'toSeq': 1,
    'payload': {
      'kind': 'snapshot',
      'snapshot': {
        'sessionId': 's1',
        'logEpoch': 'e1',
        'revision': 1,
        ...snapshot,
      },
    },
  }, onGap: () {});
  return state;
}

Widget _wrap(ConversationState state) => MaterialApp(
      home: Scaffold(
        body: GoalPanel(
          state: state,
          onPauseGoal: (_) async {},
          onResumeGoal: (_) async {},
        ),
      ),
    );

void main() {
  final goal = {
    'summaryTitle': 'Commit 后按方案逐步执行并验证',
    'objective': '没问题 先 commit 然后上面的方案 step by step 的做',
    'timeUsedSeconds': 1186,
    'status': 'active',
    'iterations': [
      {
        'iteration': 1,
        'items': [
          {'id': 'a', 'content': 'commit 当前基线', 'status': 'completed'},
          {'id': 'b', 'content': '批 D：符号改名', 'status': 'inProgress'},
          {'id': 'c', 'content': '批 E：类型化', 'status': 'pending'},
        ],
      },
    ],
  };

  testWidgets('renders goal title, progress and pending items', (tester) async {
    final state = _stateWith({
      'goal': goal,
      'subagents': {
        'running': [
          {
            'title': '类型化三个 main chunk 文件',
            'status': 'running',
            'startedAt': DateTime.now().millisecondsSinceEpoch - 60000,
          },
        ],
      },
    });
    await tester.pumpWidget(_wrap(state));
    await tester.pump();

    expect(find.text('目标'), findsOneWidget);
    expect(find.text('19 分 46 秒'), findsOneWidget);
    expect(find.text('Commit 后按方案逐步执行并验证'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget); // 1 completed of 3
    // completed items are collapsed: only inProgress + pending visible
    expect(find.text('批 D：符号改名'), findsOneWidget);
    expect(find.text('批 E：类型化'), findsOneWidget);
    expect(find.text('commit 当前基线'), findsNothing);
    // running subagent with elapsed time
    expect(find.text('类型化三个 main chunk 文件'), findsOneWidget);
    expect(find.textContaining('已运行 1 分'), findsOneWidget);
  });

  testWidgets('expanding shows completed items', (tester) async {
    final state = _stateWith({'goal': goal});
    await tester.pumpWidget(_wrap(state));
    await tester.pump();

    await tester.tap(find.textContaining('已完成 1 项'));
    await tester.pump();

    expect(find.text('commit 当前基线'), findsOneWidget);
  });

  testWidgets('no goal renders nothing', (tester) async {
    final state = _stateWith({});
    await tester.pumpWidget(_wrap(state));
    await tester.pump();
    expect(find.text('目标'), findsNothing);
  });
}
