import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:zlinker/ui/chat/markdown_view.dart';
import 'package:zlinker/ui/theme.dart';
import 'package:zlinker/ui/ui_settings.dart';

Widget wrap(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      builder: (context, child) =>
          UiSettingsProvider(settings: UiSettings(), child: child!),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders paragraphs and inline code', (tester) async {
    await tester.pumpWidget(wrap(const ZLinkerMarkdown(
        'Hello **world**, see `doThing()` for details.')));
    expect(find.textContaining('Hello'), findsOneWidget);
    expect(find.textContaining('doThing()'), findsOneWidget);
  });

  testWidgets('fenced code block gets language header + copy button',
      (tester) async {
    await tester.pumpWidget(wrap(const ZLinkerMarkdown(
        '```dart\nvoid main() {}\n```')));
    await tester.pumpAndSettle();
    expect(find.text('dart'), findsOneWidget);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.copy_outlined));
    await tester.pumpAndSettle();
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('unordered list renders', (tester) async {
    await tester.pumpWidget(wrap(const ZLinkerMarkdown('- one\n- two')));
    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
  });

  testWidgets('known language gets token-colored spans', (tester) async {
    await tester.pumpWidget(wrap(const ZLinkerMarkdown(
        '```dart\n// hi\nvoid main() {}\n```')));
    await tester.pumpAndSettle();
    // The comment token carries the dark-theme comment color (#6A9955).
    final context = tester.element(find.textContaining('// hi'));
    final span = context
        .findAncestorWidgetOfExactType<SelectableText>()!
        .textSpan!;
    final comment = findSpan(span, (s) => s.text == '// hi')!;
    expect(comment.style!.color, const Color(0xFF6A9955));
  });

  testWidgets('unknown language falls back to plain monospace',
      (tester) async {
    await tester.pumpWidget(
        wrap(const ZLinkerMarkdown('```obscurelang\nplain text here\n```')));
    await tester.pumpAndSettle();
    final context = tester.element(find.textContaining('plain text here'));
    final span =
        context.findAncestorWidgetOfExactType<SelectableText>()!.textSpan!;
    // Single unstyled run keeps the inherited ZInk.codeText color.
    final run = findSpan(span, (s) => s.text == 'plain text here')!;
    expect(run.style, isNull);
  });
}

TextSpan? findSpan(InlineSpan root, bool Function(TextSpan) predicate) {
  if (root is TextSpan) {
    if (predicate(root)) return root;
    for (final child in root.children ?? const <InlineSpan>[]) {
      final hit = findSpan(child, predicate);
      if (hit != null) return hit;
    }
  }
  return null;
}
