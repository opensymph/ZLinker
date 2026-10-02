import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/chat/chat_message_list.dart';

void main() {
  Map<String, dynamic> tool(String name, {String status = 'completed'}) => {
        'kind': 'toolCall',
        'toolName': name,
        'status': status,
        'inputText': 'x',
      };

  test('consecutive execute tools merge into one rowGroup', () {
    final parts = assistantTurnParts([
      tool('bash'),
      tool('terminal'),
      tool('bash'),
    ]).parts;
    expect(parts, hasLength(1));
    expect(parts.single.kind, 'rowGroup');
    expect(parts.single.group, hasLength(3));
  });

  test('a text row splits the run; single execute stays a row', () {
    final parts = assistantTurnParts([
      tool('bash'),
      {'kind': 'assistantText', 'text': 'done'},
      tool('terminal'),
    ]).parts;
    expect(parts, hasLength(3));
    expect(parts[0].kind, 'row');
    expect(parts[0].group, isNull);
    expect(parts[1].kind, 'text');
    expect(parts[2].kind, 'row');
  });

  test('non-execute tools are not grouped', () {
    final parts = assistantTurnParts([
      tool('readFile'),
      tool('writeFile'),
    ]).parts;
    expect(parts, hasLength(2));
    for (final p in parts) {
      expect(p.kind, 'row');
      expect(p.group, isNull);
    }
  });
}
