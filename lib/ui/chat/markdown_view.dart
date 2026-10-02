import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:highlight/highlight.dart' as hl;
import 'package:markdown/markdown.dart' as md;

import '../theme.dart';
import '../ui_settings.dart';

/// Markdown renderer matching the official web client look: selectable
/// body text, inline code on a pill background, fenced code blocks with a
/// language tag and copy button in a self-drawn header bar.
class ZLinkerMarkdown extends StatelessWidget {
  final String data;
  final bool selectable;
  final double fontSize;

  const ZLinkerMarkdown(
    this.data, {
    super.key,
    this.selectable = true,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    final codeFont = fontSize - 1.5;
    final styleSheet = MarkdownStyleSheet(
      p: TextStyle(fontSize: fontSize, height: 1.6, color: ZInk.solid(context)),
      h1: const TextStyle(
          fontSize: 20, fontWeight: FontWeight.w700, height: 1.6),
      h2: const TextStyle(
          fontSize: 18, fontWeight: FontWeight.w700, height: 1.6),
      h3: const TextStyle(
          fontSize: 16, fontWeight: FontWeight.w600, height: 1.6),
      h4: const TextStyle(
          fontSize: 15, fontWeight: FontWeight.w600, height: 1.6),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: codeFont,
        backgroundColor: ZInk.codeInlineBg(context),
        color: ZInk.solid(context),
      ),
      codeblockDecoration: const BoxDecoration(),
      blockquote:
          TextStyle(fontSize: fontSize, color: ZInk.soft(context), height: 1.6),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
              color: ZColors.sky500.withValues(alpha: 0.5), width: 3),
        ),
      ),
      blockquotePadding: const EdgeInsets.only(left: 12),
      listBullet: TextStyle(
          fontSize: fontSize, height: 1.6, color: ZInk.solid(context)),
      tableBody: TextStyle(fontSize: fontSize - 1, color: ZInk.solid(context)),
      tableHead: TextStyle(
          fontSize: fontSize - 1,
          fontWeight: FontWeight.w600,
          color: ZInk.solid(context)),
      tableBorder: TableBorder.all(color: ZInk.hairline(context), width: 1),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: ZInk.hairline(context))),
      ),
      a: TextStyle(color: ZColors.sky500, decoration: TextDecoration.underline),
    );

    return MarkdownBody(
      data: data,
      selectable: selectable,
      styleSheet: styleSheet,
      builders: {
        'code': _CodeBlockBuilder(codeFontSize: codeFont),
      },
      softLineBreak: true,
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  final double codeFontSize;

  _CodeBlockBuilder({required this.codeFontSize});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // Language is encoded in the class attribute: `language-dart`.
    var language = '';
    final classAttr = element.attributes['class'];
    if (classAttr != null) {
      final match = RegExp(r'language-(\S+)').firstMatch(classAttr);
      if (match != null) language = match.group(1) ?? '';
    }
    final code = element.textContent;
    if (!code.contains('\n') && language.isEmpty) {
      // inline code: default styling
      return null;
    }
    return _CodeBlock(code: code, language: language, fontSize: codeFontSize);
  }
}

class _CodeBlock extends StatelessWidget {
  final String code;
  final String language;
  final double fontSize;

  const _CodeBlock({
    required this.code,
    required this.language,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: ZInk.codeBlockBg(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: ZInk.tile(context),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(
              children: [
                Text(
                  language.isEmpty ? 'code' : language,
                  style: TextStyle(
                      fontSize: 10.5,
                      color: ZInk.faint(context),
                      fontFamily: 'monospace'),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(tr(context, 'chat.copied')),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.copy_outlined,
                        size: 13, color: ZInk.faint(context)),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(10),
            child: SelectableText.rich(
              _highlightedCode(context),
            ),
          ),
        ],
      ),
    );
  }

  TextSpan _highlightedCode(BuildContext context) {
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: fontSize,
      height: 1.5,
      color: ZInk.codeText(context),
    );
    final plain =
        code.endsWith('\n') ? code.substring(0, code.length - 1) : code;
    final theme = Theme.of(context).brightness == Brightness.dark
        ? _CodeTheme.dark
        : _CodeTheme.light;
    return _highlightCode(plain, language, base, theme);
  }
}

/// Syntax-highlight palette for fenced code blocks: VSCode Dark+ tones on
/// the dark surface, GitHub Light tones on light. Plain text keeps the
/// inherited [ZInk.codeText] color.
class _CodeTheme {
  final Map<String, Color> tokens;
  const _CodeTheme(this.tokens);

  static const dark = _CodeTheme({
    'keyword': Color(0xFF569CD6),
    'selector-tag': Color(0xFF569CD6),
    'literal': Color(0xFF569CD6),
    'tag': Color(0xFF569CD6),
    'built_in': Color(0xFF4EC9B0),
    'type': Color(0xFF4EC9B0),
    'class': Color(0xFF4EC9B0),
    'number': Color(0xFFB5CEA8),
    'symbol': Color(0xFFB5CEA8),
    'bullet': Color(0xFFB5CEA8),
    'string': Color(0xFFCE9178),
    'regexp': Color(0xFFD16969),
    'comment': Color(0xFF6A9955),
    'quote': Color(0xFF6A9955),
    'title': Color(0xFFDCDCAA),
    'name': Color(0xFFDCDCAA),
    'function': Color(0xFFDCDCAA),
    'section': Color(0xFFDCDCAA),
    'attr': Color(0xFF9CDCFE),
    'property': Color(0xFF9CDCFE),
    'variable': Color(0xFF9CDCFE),
    'meta': Color(0xFFC586C0),
    'deletion': Color(0xFFFF7B72),
    'addition': Color(0xFF7EE787),
  });

  static const light = _CodeTheme({
    'keyword': Color(0xFFCF222E),
    'selector-tag': Color(0xFF116329),
    'literal': Color(0xFF0550AE),
    'tag': Color(0xFF116329),
    'built_in': Color(0xFF953800),
    'type': Color(0xFF953800),
    'class': Color(0xFF953800),
    'number': Color(0xFF0550AE),
    'symbol': Color(0xFF0550AE),
    'bullet': Color(0xFF0550AE),
    'string': Color(0xFF0A3069),
    'regexp': Color(0xFF116329),
    'comment': Color(0xFF6E7781),
    'quote': Color(0xFF6E7781),
    'title': Color(0xFF8250DF),
    'name': Color(0xFF8250DF),
    'function': Color(0xFF8250DF),
    'section': Color(0xFF8250DF),
    'attr': Color(0xFF0550AE),
    'property': Color(0xFF0550AE),
    'variable': Color(0xFF953800),
    'meta': Color(0xFFCF222E),
    'deletion': Color(0xFF82071E),
    'addition': Color(0xFF116329),
  });

  /// `meta-keyword` style subclass names resolve through their dash prefix.
  Color? lookup(String? className) {
    if (className == null || className.isEmpty) return null;
    final hit = tokens[className];
    if (hit != null) return hit;
    final dash = className.indexOf('-');
    if (dash > 0) return tokens[className.substring(0, dash)];
    return null;
  }
}

/// Common fence-language aliases → highlight package language ids.
const Map<String, String> _langAliases = {
  'js': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'py': 'python',
  'rb': 'ruby',
  'cs': 'csharp',
  'c++': 'cpp',
  'kt': 'kotlin',
  'rs': 'rust',
  'sh': 'bash',
  'shell': 'bash',
  'zsh': 'bash',
  'console': 'bash',
  'yml': 'yaml',
  'ps1': 'powershell',
  'objc': 'objectivec',
  'html': 'xml',
  'svg': 'xml',
  'jsonc': 'json',
  'md': 'markdown',
};

/// Highlights [code] with the `highlight` package; unknown language ids fall
/// back to the package's plaintext mode and parse failures to the plain base
/// style (previous behavior).
TextSpan _highlightCode(
  String code,
  String language,
  TextStyle base,
  _CodeTheme theme,
) {
  if (code.isEmpty) return TextSpan(text: code, style: base);
  final langId = _langAliases[language] ?? language;
  if (langId.isEmpty) return TextSpan(text: code, style: base);
  hl.Result result;
  try {
    result = hl.highlight.parse(code, language: langId);
  } catch (_) {
    return TextSpan(text: code, style: base);
  }
  final nodes = result.nodes;
  if (nodes == null || nodes.isEmpty) {
    return TextSpan(text: code, style: base);
  }
  return TextSpan(style: base, children: [_spanForNodes(nodes, theme)]);
}

TextSpan _spanForNodes(List<hl.Node> nodes, _CodeTheme theme,
    [String? inherited]) {
  final children = <TextSpan>[];
  for (final node in nodes) {
    final cls = (node.className != null && node.className!.isNotEmpty)
        ? node.className
        : inherited;
    final value = node.value;
    if (value != null && value.isNotEmpty) {
      final color = theme.lookup(node.className) ?? theme.lookup(inherited);
      children.add(TextSpan(
        text: value,
        style: color == null ? null : TextStyle(color: color),
      ));
    } else if (node.children != null && node.children!.isNotEmpty) {
      children.add(_spanForNodes(node.children!, theme, cls));
    }
  }
  return children.isEmpty
      ? const TextSpan(text: '')
      : TextSpan(children: children);
}
