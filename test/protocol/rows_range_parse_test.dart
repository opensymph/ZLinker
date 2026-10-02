import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/protocol/conversation.dart';

void main() {
  ConversationState stateWithWindow({
    required List<Map<String, dynamic>> window,
    int? totalCount,
    Object? firstRowId = _sentinel,
  }) {
    final state = ConversationState();
    final rowsObj = <String, dynamic>{
      'window': window,
      if (totalCount != null) 'totalCount': totalCount,
      // firstRowId intentionally absent unless the test passes it — the
      // live snapshot is NOT guaranteed to carry it (web pages on
      // window[0].rowId instead).
      if (!identical(firstRowId, _sentinel)) 'firstRowId': firstRowId,
    };
    state.applyFrame({
      'toSeq': 1,
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'sessionId': 's1',
          'logEpoch': 'e1',
          'revision': 1,
          'rows': rowsObj,
        },
      },
    }, onGap: () {});
    return state;
  }

  Map<String, dynamic> row(int id) => {'rowId': id, 'kind': 'assistantText'};

  test('missing snapshot firstRowId falls back to window head (web cursor)',
      () {
    final state = stateWithWindow(
      window: [row(10), row(11)],
      totalCount: 50,
    );
    expect(state.firstRowId, 10, reason: 'web pages on window[0].rowId');
    expect(state.canLoadOlder, isTrue);
  });

  test('pagination cursor is the window first row; store firstRowId is the '
      'at-top anchor', () {
    // Official rowsWindow semantics: firstRowId is the STORE-first row
    // ("window 首行等于它 ⇔ 已到顶"); the pagination cursor is the window's
    // first row (web loadOlder sends snapshot.rows.window[0].rowId).
    final state = stateWithWindow(
      window: [row(10), row(11)],
      totalCount: 50,
      firstRowId: 9,
    );
    expect(state.firstRowId, 10);
    expect(state.storeFirstRowId, 9);
    expect(state.canLoadOlder, isTrue); // window 10 != store 9
  });

  test('rangeEnvelopeMatches guards on logEpoch', () {
    final state = stateWithWindow(window: [row(10)], totalCount: 5);
    expect(state.rangeEnvelopeMatches('e1'), isTrue);
    expect(state.rangeEnvelopeMatches('e2'), isFalse);
    expect(state.rangeEnvelopeMatches(null), isTrue);
  });

  test('hasMore from the response drives canLoadOlder (web paging)', () {
    final state = stateWithWindow(
      window: [row(10), row(11)],
      totalCount: 2,
    );
    // totals equal → heuristic says no more
    expect(state.canLoadOlder, isFalse);
    // but the server said there is more — hasMore wins
    state.hasMore = true;
    expect(state.canLoadOlder, isTrue);
    // server said done — no more even if totals drift
    state.hasMore = false;
    expect(state.canLoadOlder, isFalse);
  });

  test('prependOlderRows merges, dedupes and moves the cursor', () {
    final state = stateWithWindow(
      window: [row(10), row(11)],
      totalCount: 50,
    );
    state.prependOlderRows([row(8), row(9), row(10)], 8);
    expect(state.rows.map((r) => r['rowId']), [8, 9, 10, 11]);
    expect(state.firstRowId, 8);
  });
}

class _Absent { const _Absent(); }
const _sentinel = _Absent();
