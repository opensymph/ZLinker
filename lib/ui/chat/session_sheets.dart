import 'dart:convert';

import 'package:flutter/material.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'diff_view.dart';
import 'markdown_view.dart';

/// Structured sheets for the chat page's 计划 / 文件变更 entries, replacing
/// the raw-JSON dumps. Shapes mirror the official web client:
/// `v4/conversation/plans` → ExitPlanMode toolCall rows (rowId desc);
/// `v4/conversation/fileChanges` → per-file items with readonly hunks.

/// Extracts the plan markdown from an ExitPlanMode toolCall row, mirroring
/// the web `planToolCall.ts` fallback chain: input.plan/text/content →
/// inputText JSON → output → raw.rawInput/rawOutput → raw.content[].
String extractPlanMarkdown(Map row) {
  String? from(Map source) {
    for (final key in const ['plan', 'text', 'content']) {
      final v = source[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  final input = row['input'];
  if (input is Map) {
    final m = from(input.cast<String, dynamic>());
    if (m != null) return m;
  }
  final inputText = row['inputText'];
  if (inputText is String && inputText.trim().isNotEmpty) {
    try {
      final parsed = jsonDecode(inputText);
      if (parsed is Map) {
        final m = from(parsed.cast<String, dynamic>());
        if (m != null) return m;
      }
    } catch (_) {
      // Streaming inputText may not be complete JSON yet.
    }
  }
  final output = row['output'];
  if (output is Map) {
    final m = from(output.cast<String, dynamic>());
    if (m != null) return m;
  }
  final raw = row['raw'];
  if (raw is Map) {
    final rawMap = raw.cast<String, dynamic>();
    for (final candidate in [rawMap['rawInput'], rawMap['rawOutput']]) {
      if (candidate is Map) {
        final m = from(candidate.cast<String, dynamic>());
        if (m != null) return m;
      }
    }
    final content = rawMap['content'];
    if (content is List) {
      for (final entry in content) {
        if (entry is! Map) continue;
        final nested =
            entry['content'] is Map ? entry['content'] as Map : entry;
        final m = from(nested.cast<String, dynamic>());
        if (m != null) return m;
      }
    }
  }
  return '';
}

/// First heading (else first non-empty line) as the plan directory title.
String? planDirectoryTitle(String markdown) {
  final h1 = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(markdown);
  if (h1 != null) return h1.group(1)?.trim();
  for (final line in markdown.split(RegExp(r'\r?\n'))) {
    final title = line.replaceFirst(RegExp(r'^[#>*\-\s]+'), '').trim();
    if (title.isNotEmpty) return title;
  }
  return null;
}

/// 计划 sheet: the live snapshot plan on top, the historical ExitPlanMode
/// directory (from the plans RPC) underneath.
class PlansSheet extends StatelessWidget {
  final ConversationState? state;

  /// ExitPlanMode toolCall rows from the plans RPC (rowId desc).
  final List<Map> planRows;

  const PlansSheet({super.key, required this.state, required this.planRows});

  List<Map> get _currentItems {
    final plan = state?.snapshot?['plan'];
    final items = plan is Map ? plan['items'] : null;
    return items is List ? items.whereType<Map>().toList() : const <Map>[];
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentItems;
    final done = current.where((i) => i['status'] == 'completed').length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(context, 'chat.plans'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (current.isNotEmpty) ...[
                      Row(
                        children: [
                          Text(
                            tr(context, 'chat.plans.current'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: ZInk.muted(context),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '$done/${current.length}',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: ZInk.muted(context),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      for (final item in current)
                        _PlanStepRow(
                          status: '${item['status'] ?? ''}',
                          content: '${item['content'] ?? ''}',
                        ),
                      const SizedBox(height: 12),
                    ],
                    if (planRows.isNotEmpty) ...[
                      Text(
                        tr(context, 'chat.plans.history'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: ZInk.muted(context),
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (var i = 0; i < planRows.length; i++)
                        _PlanHistoryTile(index: i, row: planRows[i]),
                    ],
                    if (current.isEmpty && planRows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            tr(context, 'chat.plans.empty'),
                            style: TextStyle(
                              fontSize: 13,
                              color: ZInk.muted(context),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Todo-style plan step (pending / inProgress / completed).
class _PlanStepRow extends StatelessWidget {
  final String status;
  final String content;

  const _PlanStepRow({required this.status, required this.content});

  @override
  Widget build(BuildContext context) {
    final completed = status == 'completed';
    final inProgress = status == 'inProgress' || status == 'in_progress';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (inProgress)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              completed ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 14,
              color: completed ? ZColors.success : ZInk.ghost(context),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: completed ? ZInk.faint(context) : ZInk.soft(context),
                decoration: completed
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanHistoryTile extends StatelessWidget {
  final int index;
  final Map row;

  const _PlanHistoryTile({required this.index, required this.row});

  @override
  Widget build(BuildContext context) {
    final markdown = extractPlanMarkdown(row);
    final title = planDirectoryTitle(markdown) ??
        trP(context, 'chat.plans.planN', ['${index + 1}']);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
        ),
        subtitle: row['startedAt'] != null
            ? Text(
                '${row['startedAt']}',
                style: TextStyle(fontSize: 10.5, color: ZInk.faint(context)),
              )
            : null,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: ZLinkerMarkdown(markdown, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// 文件变更 sheet: per-file tiles with inline diffs from the readonly hunks,
/// plus a rewind entry (precheck → confirm → apply, same as the turn bar).
class FileChangesSheet extends StatefulWidget {
  final Map changes;
  final ChatGateway gateway;
  final String sessionId;
  final Map<String, dynamic> target;

  const FileChangesSheet({
    super.key,
    required this.changes,
    required this.gateway,
    required this.sessionId,
    required this.target,
  });

  @override
  State<FileChangesSheet> createState() => _FileChangesSheetState();
}

class _FileChangesSheetState extends State<FileChangesSheet> {
  bool _busy = false;

  List<Map> get _items {
    final items = widget.changes['items'];
    return items is List ? items.whereType<Map>().toList() : const <Map>[];
  }

  Future<void> _rewind() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final preview = await widget.gateway.fileRewindPreview(
        widget.sessionId,
        target: widget.target,
      );
      if (!mounted) return;
      final ok = await showRewindPreviewDialog(context, preview);
      if (ok != true) return;
      await widget.gateway.applyFileRewind(widget.sessionId, widget.target);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'chat.rewind.done'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trP(context, 'chat.action.rewind.failed', ['$e']),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final changes = widget.changes;
    final files = (changes['files'] as num?)?.toInt() ?? _items.length;
    final adds = (changes['additions'] as num?)?.toInt() ?? 0;
    final dels = (changes['deletions'] as num?)?.toInt() ?? 0;
    final reverted = changes['state'] == 'reverted';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  tr(context, 'chat.action.fileChanges'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text.rich(
                  TextSpan(
                    text: trP(context, 'chat.files.changed', ['$files']),
                    style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
                    children: [
                      if (adds > 0)
                        const TextSpan(
                          text: '  +',
                          style: TextStyle(color: ZColors.success),
                        ),
                      if (adds > 0)
                        TextSpan(
                          text: '$adds',
                          style: const TextStyle(color: ZColors.success),
                        ),
                      if (dels > 0)
                        const TextSpan(
                          text: '  -',
                          style: TextStyle(color: ZColors.danger),
                        ),
                      if (dels > 0)
                        TextSpan(
                          text: '$dels',
                          style: const TextStyle(color: ZColors.danger),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (reverted)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr(context, 'chat.files.reverted'),
                  style: TextStyle(fontSize: 12.5, color: ZColors.warning),
                ),
              ),
            const SizedBox(height: 8),
            Flexible(
              child: _items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          tr(context, 'chat.json.empty'),
                          style: TextStyle(
                            fontSize: 13,
                            color: ZInk.muted(context),
                          ),
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        children: [
                          for (final item in _items)
                            _FileChangeTile(item: item),
                        ],
                      ),
                    ),
            ),
            if (!reverted && _items.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ZColors.danger,
                    side: BorderSide(
                        color: ZColors.danger.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: _busy ? null : _rewind,
                  child: Text(
                    tr(context, 'chat.files.undo'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FileChangeTile extends StatelessWidget {
  final Map item;

  const _FileChangeTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final path = '${item['path'] ?? ''}';
    final adds = (item['additions'] as num?)?.toInt() ?? 0;
    final dels = (item['deletions'] as num?)?.toInt() ?? 0;
    final patches =
        item['patches'] is List ? item['patches'] as List : const [];
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        title: Text(
          path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            fontFamily: 'monospace',
            color: ZInk.solid(context),
          ),
        ),
        trailing: Text.rich(
          TextSpan(
            children: [
              if (adds > 0)
                TextSpan(
                  text: '+$adds',
                  style: const TextStyle(color: ZColors.success),
                ),
              if (adds > 0 && dels > 0) const TextSpan(text: ' '),
              if (dels > 0)
                TextSpan(
                  text: '-$dels',
                  style: const TextStyle(color: ZColors.danger),
                ),
            ],
          ),
          style: const TextStyle(fontSize: 11.5),
        ),
        children: [
          DiffView(diff: _diffFromPatches(path, patches)),
        ],
      ),
    );
  }

  /// Readonly hunks ({oldStart,oldLines,newStart,newLines,lines}) → the
  /// shared DiffData line model ("+"/"-"/space prefixed).
  DiffData _diffFromPatches(String path, List patches) {
    final lines = <DiffLine>[];
    for (final hunk in patches) {
      if (hunk is! Map) continue;
      final hunkLines = hunk['lines'];
      if (hunkLines is! List) continue;
      for (final line in hunkLines) {
        if (line is! String) continue;
        if (line.startsWith('+')) {
          lines.add(DiffLine(DiffLineType.added, line));
        } else if (line.startsWith('-')) {
          lines.add(DiffLine(DiffLineType.removed, line));
        } else {
          lines.add(DiffLine(DiffLineType.context, line));
        }
      }
    }
    return DiffData(filePath: path, lines: lines);
  }
}

/// Web rewind precheck dialog (conversationFileRewindPreviewV4 runs before
/// any write). A preview reporting unrewritable files (or errors) blocks
/// the rewind entirely. Shared by the turn bar and the changes sheet.
Future<bool?> showRewindPreviewDialog(
  BuildContext context,
  dynamic preview,
) {
  final files = rewindPreviewFiles(preview);
  final blocked = preview == null ||
      (preview is Map && preview['error'] != null) ||
      (preview is Map &&
          (preview['canRewind'] == false || preview['rewritable'] == false));
  return showDialog<bool>(
    context: context,
    useRootNavigator: false,
    builder: (dialogCtx) => AlertDialog(
      title: Text(
        tr(dialogCtx,
            blocked ? 'chat.rewind.unsafeTitle' : 'chat.rewind.safeTitle'),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: files.isEmpty && !blocked
            ? Text(tr(dialogCtx, 'chat.rewind.checking'),
                style: TextStyle(fontSize: 13, color: ZInk.soft(dialogCtx)))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (blocked)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        tr(dialogCtx, 'chat.rewind.cannotApply'),
                        style: TextStyle(fontSize: 13, color: ZColors.danger),
                      ),
                    ),
                  for (final f in files.take(12))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        f,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5, color: ZInk.soft(dialogCtx)),
                      ),
                    ),
                  if (files.length > 12)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '+${files.length - 12}',
                        style: TextStyle(
                            fontSize: 12, color: ZInk.muted(dialogCtx)),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: Text(tr(dialogCtx, 'common.cancel')),
        ),
        if (!blocked)
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(tr(dialogCtx, 'chat.rewind.confirm')),
          ),
      ],
    ),
  );
}

/// Best-effort file list extraction from the preview payload — field
/// names beyond the confirmed endpoint are not guessed further; an empty
/// list simply renders the text-only dialog.
List<String> rewindPreviewFiles(dynamic preview) {
  if (preview is! Map) return const [];
  for (final key in const ['files', 'rewritableFiles', 'entries']) {
    final v = preview[key];
    if (v is List) {
      return [
        for (final e in v)
          e is Map ? '${e['path'] ?? e['filePath'] ?? e['name'] ?? ''}' : '$e',
      ].where((f) => f.isNotEmpty).toList();
    }
  }
  return const [];
}
