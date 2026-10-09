import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'markdown_view.dart';

/// Message bubbles: user bubble (collapsible, attachments), assistant
/// bubble (markdown + feedback row), and the collapsible reasoning tile.
/// Split out of chat_message_list.dart for size.

class UserBubble extends StatefulWidget {
  final Map<String, dynamic> row;
  final ChatGateway gateway;
  final String sessionId;

  const UserBubble({
    super.key,
    required this.row,
    required this.gateway,
    required this.sessionId,
  });

  @override
  State<UserBubble> createState() => _UserBubbleState();
}

class _UserBubbleState extends State<UserBubble> {
  bool _expanded = false;

  static const _collapsedLines = 14;

  @override
  Widget build(BuildContext context) {
    final text = widget.row['text'] as String? ?? '';
    final attachments = widget.row['attachments'];
    final longText = '\n'.allMatches(text).length >= _collapsedLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(left: 56, top: 4, bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: ZInk.card(context),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (attachments is List)
                  for (final a in attachments)
                    if (a is Map)
                      _AttachmentView(
                        attachment: a.cast<String, dynamic>(),
                        gateway: widget.gateway,
                        sessionId: widget.sessionId,
                      ),
                if (text.isNotEmpty)
                  // SelectableText with maxLines inflates to maxLines height
                  // inside unbounded parents (ListView) — cap collapsed long
                  // texts with a non-scrollable clip instead.
                  longText && !_expanded
                      ? ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxHeight: _collapsedLines * 21.0,
                          ),
                          child: SingleChildScrollView(
                            physics: const NeverScrollableScrollPhysics(),
                            child: SelectableText(
                              text,
                              style: const TextStyle(fontSize: 14, height: 1.5),
                            ),
                          ),
                        )
                      : SelectableText(
                          text,
                          style: const TextStyle(fontSize: 14, height: 1.5),
                        ),
                if (longText)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: Size.zero,
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(
                      _expanded
                          ? tr(context, 'chat.collapse')
                          : tr(context, 'chat.expand'),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // copy / edit affordances sit OUTSIDE the bubble, bottom-right
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MiniAction(
              icon: Icons.copy_outlined,
              tooltip: tr(context, 'chat.copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(tr(context, 'chat.copied')),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
            ),
            _MiniAction(
              icon: Icons.edit_outlined,
              tooltip: tr(context, 'chat.action.editResend'),
              onTap: () => _promptEdit(context),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _promptEdit(BuildContext context) async {
    final controller = TextEditingController(
      text: widget.row['text'] as String? ?? '',
    );
    final newText = await showDialog<String>(
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
    if (newText == null || newText.isEmpty || !context.mounted) return;
    try {
      await widget.gateway.editUserQuery(
          widget.sessionId,
          {
            'rowId': widget.row['rowId'],
            if (widget.row['entityId'] != null)
              'entityId': widget.row['entityId'],
          },
          newText);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(trP(context, 'chat.action.edit.failed', ['$e'])),
          ),
        );
      }
    }
  }
}

class _MiniAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _MiniAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 14, color: ZInk.ghost(context)),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _AttachmentView extends StatefulWidget {
  final Map<String, dynamic> attachment;
  final ChatGateway gateway;
  final String sessionId;

  const _AttachmentView({
    required this.attachment,
    required this.gateway,
    required this.sessionId,
  });

  @override
  State<_AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<_AttachmentView> {
  Uint8List? _imageBytes;
  bool _failed = false;

  bool get _isImage =>
      '${widget.attachment['mime'] ?? ''}'.startsWith('image/');

  @override
  void initState() {
    super.initState();
    if (_isImage) _load();
  }

  Future<void> _load() async {
    final ref = widget.attachment['ref'] as String?;
    if (ref == null) return;
    try {
      final res = await widget.gateway.attachmentRead(
        widget.sessionId,
        ref: ref,
      );
      if (mounted) setState(() => _imageBytes = res.bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = '${widget.attachment['fileName'] ?? ''}';
    if (!_isImage) {
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: ZInk.tile(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 16,
              color: ZInk.muted(context),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                fileName,
                style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    if (_failed) {
      return Text(
        trP(context, 'chat.attach.loadFailed', [fileName]),
        style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
      );
    }
    if (_imageBytes == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(_imageBytes!, width: 220, fit: BoxFit.cover),
      ),
    );
  }
}

/// Full-width assistant markdown (no bubble); feedback row (copy / like /
/// dislike / fork) hangs off the last text segment of a turn.
class AssistantBubble extends StatelessWidget {
  final Map<String, dynamic> row;
  final ChatGateway gateway;
  final String sessionId;
  final ConversationState state;
  final bool showFeedback;

  const AssistantBubble({
    super.key,
    required this.row,
    required this.gateway,
    required this.sessionId,
    required this.state,
    this.showFeedback = true,
  });

  void _setFeedback(String? value) {
    if (sessionId.isEmpty) return;
    // Optimistic: update the icon instantly; server row.upserted confirms.
    state.optimisticRowUpdate(row['rowId'] as num?, {'feedback': value});
    gateway.setAssistantFeedback(
        sessionId,
        {
          'rowId': row['rowId'],
          if (row['entityId'] != null) 'entityId': row['entityId'],
        },
        value);
  }

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final streaming = row['state'] == 'streaming';
    final feedback = row['feedback'] as String?;
    final timestamp = rowTimestamp(row);
    return Container(
      margin: const EdgeInsets.only(right: 24, top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZLinkerMarkdown(text),
          if (showFeedback)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (streaming)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  )
                else ...[
                  _FeedbackButton(
                    icon: Icons.copy_outlined,
                    active: false,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(tr(context, 'chat.copied')),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_up_alt_outlined,
                    active: feedback == 'like',
                    onTap: () =>
                        _setFeedback(feedback == 'like' ? null : 'like'),
                  ),
                  _FeedbackButton(
                    icon: Icons.thumb_down_alt_outlined,
                    active: feedback == 'dislike',
                    onTap: () =>
                        _setFeedback(feedback == 'dislike' ? null : 'dislike'),
                  ),
                  _FeedbackButton(
                    icon: Icons.fork_right,
                    active: false,
                    onTap: () => gateway.forkAssistant(sessionId, {
                      'rowId': row['rowId'],
                      if (row['entityId'] != null) 'entityId': row['entityId'],
                    }),
                  ),
                ],
                const Spacer(),
                if (timestamp != null && !streaming)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      _formatClock(timestamp),
                      style: TextStyle(
                        fontSize: 10,
                        color: ZInk.ghost(context),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static String _formatClock(int ms) {
    final time = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
  }
}

class _FeedbackButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _FeedbackButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        icon,
        size: 15,
        color: active ? ZColors.sky500 : ZInk.ghost(context),
      ),
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Collapsible "思考过程" strip.
class ReasoningTile extends StatelessWidget {
  final String text;
  final bool streaming;

  const ReasoningTile({super.key, required this.text, this.streaming = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ZInk.tile(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: ZInk.hairline(context)),
      ),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(
          children: [
            Icon(
              Icons.psychology_outlined,
              size: 14,
              color: streaming ? ZColors.sky400 : ZInk.faint(context),
            ),
            const SizedBox(width: 6),
            Text(
              streaming
                  ? tr(context, 'chat.reasoning.thinking')
                  : tr(context, 'chat.reasoning'),
              style: TextStyle(fontSize: 12, color: ZInk.muted(context)),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ZLinkerMarkdown(text, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Best-effort row timestamp in ms (createdAt/sentAt/at).
int? rowTimestamp(Map<String, dynamic>? row) {
  if (row == null) return null;
  for (final key in const ['createdAt', 'sentAt', 'at']) {
    final v = row[key];
    if (v is num && v > 0) return v.toInt();
  }
  return null;
}
