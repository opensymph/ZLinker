import 'package:flutter/material.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'chat_bubbles.dart';
import 'chat_page.dart';
import 'workflow_run_page.dart';
import 'session_sheets.dart';
import 'tool_call_tile.dart';

/// Message timeline widgets: turn grouping (groupTurnRows parity via
/// [groupTurnRows] + [assistantTurnParts]), user/assistant bubbles,
/// reasoning tile, timeline markers, file-changes bar with rewind, time
/// dividers, search bar and the turn-navigator rail. Split out of
/// chat_page.dart for size.

/// One ordered part of an assistant turn: either a merged text segment
/// (kind == 'text') or a non-text row (kind == 'row').
typedef AssistantPart = ({
  String kind,
  String? text,
  Map<String, dynamic>? row,
  List<Map<String, dynamic>>? group,
  bool streaming,
});

/// Splits an assistant-turn group into ORDERED parts — consecutive
/// assistantText rows merge into one text segment, while reasoning/tool/
/// subagent rows stay exactly where they occurred in the stream (so
/// "thinking → tool → answer" never renders as "answer → thinking").
typedef AssistantTurnParts = ({
  List<AssistantPart> parts,
  Map<String, dynamic>? header,
  bool streaming,
});

/// Execute-family tool rows (bash/terminal/exec/...) share one summary
/// card when consecutive — web executeGroup「终端 · N 个命令」parity.
bool _isExecuteTool(Map<String, dynamic> row) {
  if (row['kind'] != 'toolCall') return false;
  final t = '${row['toolName'] ?? ''}'.toLowerCase();
  return t.contains('bash') ||
      t.contains('terminal') ||
      t.contains('exec') ||
      t.contains('command');
}

AssistantTurnParts assistantTurnParts(List<Map<String, dynamic>> rows) {
  final parts = <AssistantPart>[];
  Map<String, dynamic>? header;
  StringBuffer? buf;
  Map<String, dynamic>? template;
  var anyStream = false;
  var sawStreaming = false;
  final executeRun = <Map<String, dynamic>>[];

  void flushText() {
    if (template != null) {
      final text = buf!.toString().trim();
      if (text.isNotEmpty) {
        parts.add((
          kind: 'text',
          text: text,
          row: template,
          group: null,
          streaming: anyStream,
        ));
      }
      buf = null;
      template = null;
      anyStream = false;
    }
  }

  void flushExecuteRun() {
    if (executeRun.isEmpty) return;
    if (executeRun.length == 1) {
      parts.add((
        kind: 'row',
        text: null,
        row: executeRun.single,
        group: null,
        streaming: false,
      ));
    } else {
      parts.add((
        kind: 'rowGroup',
        text: null,
        row: executeRun.first,
        group: List.of(executeRun),
        streaming: false,
      ));
    }
    executeRun.clear();
  }

  for (final row in rows) {
    final kind = row['kind'];
    if (kind == 'assistantText') {
      flushExecuteRun();
      template ??= row;
      buf ??= StringBuffer();
      final t = row['text'] as String? ?? '';
      if (buf!.isNotEmpty) buf!.write('\n\n');
      buf!.write(t);
      if (row['state'] == 'streaming') {
        anyStream = true;
        sawStreaming = true;
      }
    } else if (kind == 'turnHeader') {
      header = row;
    } else if (_isExecuteTool(row)) {
      flushText();
      executeRun.add(row);
    } else {
      flushExecuteRun();
      parts.add((
        kind: 'row',
        text: null,
        row: row,
        group: null,
        streaming: false,
      ));
    }
  }
  flushText();
  flushExecuteRun();
  return (parts: parts, header: header, streaming: sawStreaming);
}

/// Groups rows into turns (mirrors the web timeline): a user message starts
/// a new group; assistant text/reasoning/tool rows that follow belong to
/// the same turn and render as ONE message instead of many bubbles.
///
/// A new group starts only on a user message (or the first assistant row
/// after one). Consecutive assistant rows are merged into a single group
/// EVEN IF the server bumps `turnId` mid-response, so one answer never
/// splits into several bubbles each carrying its own feedback buttons.
List<List<Map<String, dynamic>>> groupTurnRows(
    List<Map<String, dynamic>> rows) {
  final groups = <List<Map<String, dynamic>>>[];
  List<Map<String, dynamic>>? current;
  for (final row in rows) {
    final kind = row['kind'];
    if (kind == 'timelineMarker') {
      current = null;
      groups.add([row]);
      continue;
    }
    final isUser = kind == 'userInput';
    final startsGroup =
        isUser || current == null || current.first['kind'] == 'userInput';
    if (startsGroup) {
      current = [row];
      groups.add(current);
    } else {
      current.add(row);
    }
  }
  return groups;
}

class TurnGroupWidget extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final ChatGateway gateway;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;

  const TurnGroupWidget({
    super.key,
    required this.rows,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
  });

  @override
  State<TurnGroupWidget> createState() => _TurnGroupWidgetState();
}

/// One turn group: user bubble (if any) → turn header (已工作 N + pill,
/// official renders it at the TOP of the turn) → ordered assistant parts →
/// file-changes card (official always-visible rounded bar with 撤销).
class _TurnGroupWidgetState extends State<TurnGroupWidget> {
  bool _showChanges = true;

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final gateway = widget.gateway;
    final sessionId = widget.sessionId;
    final onAction = widget.onAction;
    // single timeline marker
    if (rows.length == 1 && rows.first['kind'] == 'timelineMarker') {
      return _TimelineMarkerWidget(row: rows.first);
    }
    final first = rows.first;
    final isUserTurn = first['kind'] == 'userInput';

    // The header row moves out of the stream so it renders at the top;
    // for user turns the bubble itself is rendered separately below.
    Map<String, dynamic>? header;
    final bodyRows = <Map<String, dynamic>>[];
    for (var i = 0; i < rows.length; i++) {
      if (isUserTurn && i == 0) continue;
      final row = rows[i];
      if (row['kind'] == 'turnHeader') {
        header = row;
      } else {
        bodyRows.add(row);
      }
    }

    final children = <Widget>[];

    if (isUserTurn) {
      children.add(
        _RowWidget(
          row: first,
          gateway: gateway,
          sessionId: sessionId,
          onAction: onAction,
          state: widget.state,
        ),
      );
    }
    if (header != null) {
      children.add(
        TurnHeader(
          row: header,
          hasChanges: header['fileChanges'] is Map,
          expanded: _showChanges,
          onToggle: () => setState(() => _showChanges = !_showChanges),
        ),
      );
    }

    // assistant parts in original order (reasoning → text → tool → text …);
    // feedback buttons appear only on the LAST text segment.
    final parts = assistantTurnParts(bodyRows);
    var lastTextIdx = -1;
    for (var i = 0; i < parts.parts.length; i++) {
      if (parts.parts[i].kind == 'text') lastTextIdx = i;
    }
    for (var i = 0; i < parts.parts.length; i++) {
      final p = parts.parts[i];
      if (p.kind == 'text') {
        children.add(
          _RowWidget(
            row: {
              ...?p.row,
              'kind': 'assistantText',
              'text': p.text,
              if (p.streaming) 'state': 'streaming',
            },
            showFeedback: i == lastTextIdx,
            gateway: gateway,
            sessionId: sessionId,
            onAction: onAction,
            state: widget.state,
          ),
        );
      } else if (p.kind == 'rowGroup') {
        children.add(
          ToolGroupCard(
            rows: p.group ?? [if (p.row != null) p.row!],
            gateway: gateway,
            sessionId: sessionId,
            onAction: onAction,
            state: widget.state,
          ),
        );
      } else {
        children.add(
          _RowWidget(
            row: p.row!,
            showFeedback: false,
            gateway: gateway,
            sessionId: sessionId,
            onAction: onAction,
            state: widget.state,
          ),
        );
      }
    }

    // Official file-changes card at the end of the turn.
    final fileChanges = header?['fileChanges'];
    if (fileChanges is Map && _showChanges) {
      children.add(
        _FileChangesBar(
          changes: fileChanges.cast<String, dynamic>(),
          gateway: gateway,
          sessionId: sessionId,
          row: header!,
          onAction: onAction,
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

class _RowWidget extends StatelessWidget {
  final Map<String, dynamic> row;
  final ChatGateway gateway;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;
  final bool showFeedback;

  const _RowWidget({
    required this.row,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
    this.showFeedback = true,
  });

  Map<String, dynamic> get _target => {
        'rowId': row['rowId'],
        if (row['entityId'] != null) 'entityId': row['entityId'],
      };

  void _showActions(BuildContext context) {
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kind == 'userInput')
              ListTile(
                leading: const Icon(Icons.edit_outlined, size: 20),
                title: Text(tr(context, 'chat.action.editResend')),
                onTap: () {
                  Navigator.pop(context);
                  _editQuery(context);
                },
              ),
            ListTile(
              leading: const Icon(Icons.replay, size: 20),
              title: Text(tr(context, 'chat.action.retry')),
              onTap: () {
                Navigator.pop(context);
                onAction(
                  tr(context, 'chat.action.retry.failed'),
                  () => gateway.retryTurn(sessionId, _target),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.fork_right, size: 20),
              title: Text(tr(context, 'chat.action.fork')),
              onTap: () {
                Navigator.pop(context);
                onAction(
                  tr(context, 'chat.action.fork.failed'),
                  () => gateway.forkAssistant(sessionId, _target),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.history, size: 20),
              title: Text(tr(context, 'chat.action.rewind')),
              onTap: () {
                Navigator.pop(context);
                _confirmRewind(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.difference_outlined, size: 20),
              title: Text(tr(context, 'chat.action.fileChanges')),
              onTap: () {
                Navigator.pop(context);
                _showFileChanges(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editQuery(BuildContext context) async {
    final controller = TextEditingController(
      text: row['text'] as String? ?? '',
    );
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.action.edit.title')),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'devices.add.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr(context, 'chat.action.edit.resend')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || !context.mounted) return;
    await onAction(
      tr(context, 'chat.action.edit.failed'),
      () => gateway.editUserQuery(sessionId, _target, text),
    );
  }

  Future<void> _confirmRewind(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.action.rewind.title')),
        content: Text(tr(context, 'chat.action.rewind.body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'devices.add.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ZColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'chat.action.rewind.confirm')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await onAction(
      tr(context, 'chat.action.rewind.failed'),
      () => gateway.applyFileRewind(sessionId, _target),
    );
  }

  Future<void> _showFileChanges(BuildContext context) async {
    try {
      final changes = await gateway.fileChanges(sessionId, target: _target);
      if (!context.mounted) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (context) => FileChangesSheet(
          changes: changes is Map ? changes : const {},
          gateway: gateway,
          sessionId: sessionId,
          target: _target,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              trP(context, 'chat.action.fileChanges.failed', ['$e']),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final widget_ = switch (row['kind']) {
      'userInput' => UserBubble(
          row: row,
          gateway: gateway,
          sessionId: sessionId,
        ),
      'assistantText' => AssistantBubble(
          row: row,
          gateway: gateway,
          sessionId: sessionId,
          state: state,
          showFeedback: showFeedback,
        ),
      'reasoning' => ReasoningTile(
          text: row['text'] as String? ?? '',
          streaming: row['state'] == 'streaming',
        ),
      'toolCall' => ToolCallTile(
          row: row,
          state: state,
          onOpenActor: (actorSessionId, actorName) {
            if (actorSessionId.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text(tr(context, 'chat.workflow.actorNotStarted'))),
              );
              return;
            }
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ChatPage(
                gateway: gateway,
                sessionId: actorSessionId,
                title: actorName,
                readOnly: true,
              ),
            ));
          },
          onOpenRunDetails: (liveRun) {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => WorkflowRunPage(
                gateway: gateway,
                sessionId: sessionId,
                state: state,
                run: liveRun,
              ),
            ));
          },
        ),
      // turnHeader rows are lifted out of the stream by TurnGroupWidget
      'turnHeader' => const SizedBox.shrink(),
      'subagent' => _SubagentTile(row: row),
      'timelineMarker' => _TimelineMarkerWidget(row: row),
      _ => const SizedBox.shrink(),
    };
    final kind = row['kind'];
    if (kind != 'userInput' && kind != 'assistantText') return widget_;
    return GestureDetector(
      onLongPress: () => _showActions(context),
      child: widget_,
    );
  }
}

/// Official-style tool summary: icon + "已写入 file +N" / "终端 · cmd" /
/// "探索 · N 文件", expandable to input/output/diff.
class _FileChangesBar extends StatelessWidget {
  final Map<String, dynamic> changes;
  final ChatGateway gateway;
  final String sessionId;
  final Map<String, dynamic> row;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;

  const _FileChangesBar({
    required this.changes,
    required this.gateway,
    required this.sessionId,
    required this.row,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final adds = (changes['additions'] as num?)?.toInt() ?? 0;
    final dels = (changes['deletions'] as num?)?.toInt() ?? 0;
    final files = (changes['files'] as num?)?.toInt() ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                text: trP(context, 'chat.files.changed', ['$files']),
                style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
                children: [
                  if (adds > 0)
                    TextSpan(
                      text: '  +$adds',
                      style: const TextStyle(color: ZColors.success),
                    ),
                  if (dels > 0)
                    TextSpan(
                      text: '  -$dels',
                      style: const TextStyle(color: ZColors.danger),
                    ),
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: () => _rewindWithPreview(context),
            child: Text(
              tr(context, 'chat.files.undo'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// Web rewind precheck: conversationFileRewindPreviewV4 runs before any
  /// write. The dialog reports what the desktop returned; a preview that
  /// reports unrewritable files (or errors) blocks the rewind entirely.
  Future<void> _rewindWithPreview(BuildContext context) async {
    final target = {
      'rowId': row['rowId'],
      if (row['entityId'] != null) 'entityId': row['entityId'],
    };
    final action = onAction(
      tr(context, 'chat.action.rewind.failed'),
      () async {
        final preview =
            await gateway.fileRewindPreview(sessionId, target: target);
        if (!context.mounted) return null;
        final ok = await showRewindPreviewDialog(context, preview);
        if (ok != true) return null;
        return gateway.applyFileRewind(sessionId, target);
      },
    );
    await action;
  }
}

/// Centered timeline capsules (model switches, compaction, forks...).
class _TimelineMarkerWidget extends StatelessWidget {
  final Map<String, dynamic> row;

  const _TimelineMarkerWidget({required this.row});

  @override
  Widget build(BuildContext context) {
    final marker = row['marker'];
    if (marker is! Map) return const SizedBox.shrink();
    final type = '${marker['type'] ?? ''}';

    final (icon, text, color) = switch (type) {
      'compact' => (
          Icons.compress,
          trP(context, 'chat.marker.compact', [
            '${marker['status'] ?? ''}',
            if (marker['tokensBefore'] != null)
              trP(context, 'chat.marker.tokens', [
                '${marker['tokensBefore']}',
                '${marker['tokensAfter'] ?? '?'}',
              ])
            else
              '',
          ]),
          ZColors.sky500,
        ),
      'forkNotice' => (
          Icons.fork_right,
          tr(context, 'chat.marker.forkNotice'),
          ZInk.faint(context),
        ),
      'forkCreated' => (
          Icons.fork_right,
          tr(context, 'chat.marker.forkCreated'),
          ZInk.faint(context),
        ),
      'modelChange' => (
          Icons.swap_horiz,
          trP(context, 'chat.marker.modelChange', [
            '${marker['fromModel'] ?? ''}',
            '${marker['toModel'] ?? ''}',
          ]),
          ZColors.warning,
        ),
      'goalSet' => (
          Icons.flag_outlined,
          trP(context, 'chat.marker.goalSet', ['${marker['objective'] ?? ''}']),
          ZColors.success,
        ),
      'goalVerify' => (
          Icons.fact_check_outlined,
          trP(context, 'chat.marker.goalVerify', [
            '${marker['iteration'] ?? '?'}',
            '${marker['outcome'] ?? ''}',
          ]),
          ZColors.success,
        ),
      'retryNotice' => (
          Icons.refresh,
          trP(context, 'chat.marker.retryNotice', [
            '${marker['attempt'] ?? '?'}',
            '${marker['reasonCode'] ?? ''}',
          ]),
          ZColors.warning,
        ),
      'checkpointRestored' => (
          Icons.restore,
          tr(context, 'chat.marker.checkpointRestored'),
          ZInk.faint(context),
        ),
      _ => (Icons.info_outline, type, ZInk.faint(context)),
    };

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                text,
                style: TextStyle(fontSize: 11, color: color),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubagentTile extends StatelessWidget {
  final Map<String, dynamic> row;

  const _SubagentTile({required this.row});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.smart_toy_outlined, size: 15, color: ZInk.muted(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trP(context, 'chat.subagent', [
                    '${row['subagentType'] ?? ''}',
                  ]),
                  style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
                ),
                Text(
                  '${row['status'] ?? ''}  ${row['summaryText'] ?? ''}',
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Centered HH:mm separator between turns.
class TimeDivider extends StatelessWidget {
  final String label;

  const TimeDivider({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          label,
          style: TextStyle(fontSize: 10.5, color: ZInk.ghost(context)),
        ),
      ),
    );
  }
}

/// In-chat find bar (web conversationFind): query field, hit counter and
/// prev/next/close controls.
class ChatSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final String count;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onClose;

  const ChatSearchBar({
    super.key,
    required this.controller,
    required this.count,
    required this.onChanged,
    required this.onSubmitted,
    required this.onPrev,
    required this.onNext,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 16, color: ZInk.muted(context)),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
              decoration: InputDecoration(
                hintText: tr(context, 'chat.search.hint'),
                hintStyle: TextStyle(
                  fontSize: 12.5,
                  color: ZInk.ghost(context),
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          if (count.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                count,
                style: TextStyle(fontSize: 11, color: ZInk.muted(context)),
              ),
            ),
          IconButton(
            icon: Icon(Icons.keyboard_arrow_up,
                size: 18, color: ZInk.muted(context)),
            tooltip: tr(context, 'chat.search.prev'),
            visualDensity: VisualDensity.compact,
            onPressed: count.isEmpty ? null : onPrev,
          ),
          IconButton(
            icon: Icon(Icons.keyboard_arrow_down,
                size: 18, color: ZInk.muted(context)),
            tooltip: tr(context, 'chat.search.next'),
            visualDensity: VisualDensity.compact,
            onPressed: count.isEmpty ? null : onNext,
          ),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: ZInk.muted(context)),
            tooltip: tr(context, 'common.cancel'),
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Floating per-turn jump rail (web ConversationTurnNavigator): one marker
/// per user turn, tap to jump, wide marker on the visible turn.
class TurnNavigatorRail extends StatelessWidget {
  final int turnCount;
  final int activeIndex;
  final void Function(int) onJump;

  const TurnNavigatorRail({
    super.key,
    required this.turnCount,
    required this.activeIndex,
    required this.onJump,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 1),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 3),
        decoration: BoxDecoration(
          color: ZInk.tile(context).withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZInk.hairline(context)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < turnCount; i++)
              InkWell(
                borderRadius: BorderRadius.circular(3),
                onTap: () => onJump(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Container(
                    width: i == activeIndex ? 14 : 6,
                    height: 3,
                    decoration: BoxDecoration(
                      color: i == activeIndex
                          ? ZColors.sky500
                          : ZInk.ghost(context),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// ---------------------------------------------------------------- bars

/// Coding-plan quota banner (web ConversationQuotaBanner): mirrors the
/// sessionQuotaBannerState buckets — model_usage buckets with
/// remaining/number (percentage fallback); exhausted daily bucket →
/// daily-exhausted, exhausted other bucket → model-exhausted, <10% →
/// very-low. Silent when the desktop rejects the entitlement call.

/// Collapsed run of consecutive execute-family tool rows:
/// 「终端 · N 个命令」 — tap expands the individual tool cards.
class ToolGroupCard extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final ChatGateway gateway;
  final String sessionId;
  final Future<void> Function(String, Future<dynamic> Function()) onAction;
  final ConversationState state;

  const ToolGroupCard({
    super.key,
    required this.rows,
    required this.gateway,
    required this.sessionId,
    required this.onAction,
    required this.state,
  });

  @override
  State<ToolGroupCard> createState() => _ToolGroupCardState();
}

class _ToolGroupCardState extends State<ToolGroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.rows.length;
    var failed = 0;
    var stopped = 0;
    var lastCmd = '';
    for (final r in widget.rows) {
      final st = '${r['status'] ?? ''}';
      if (st == 'failed') failed += 1;
      if (st == 'stopped' || st == 'denied') stopped += 1;
      final input = r['inputText'] as String? ?? '';
      if (lastCmd.isEmpty && input.isNotEmpty) {
        lastCmd = input.split('\n').first;
      }
    }
    final bits = [
      trP(context, 'chat.tool.group.count', ['$n']),
      if (failed > 0) trP(context, 'chat.tool.group.failed', ['$failed']),
      if (stopped > 0) trP(context, 'chat.tool.group.stopped', ['$stopped']),
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 14, color: ZInk.muted(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${tr(context, 'chat.tool.group.terminal')} · $bits'
                      '${lastCmd.isEmpty ? '' : '  ·  $lastCmd'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: ZInk.ghost(context),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                children: [
                  for (final r in widget.rows)
                    _RowWidget(
                      row: r,
                      showFeedback: false,
                      gateway: widget.gateway,
                      sessionId: widget.sessionId,
                      onAction: widget.onAction,
                      state: widget.state,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
