// ignore_for_file: deprecated_member_use // ohos fork's Flutter predates RadioGroup; drop when it lands
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// Composer widgets for the chat page: attachment chips bar and the input
/// bar (field + toolbar: attach / skills / history / mode / usage ring /
/// model / thought / send-stop). Split out of chat_page.dart for size.

class PendingFile {
  final String fileName;
  final String mime;
  final Uint8List bytes;

  PendingFile(this.fileName, this.mime, this.bytes);
}

class PendingFilesBar extends StatelessWidget {
  final List<PendingFile> files;
  final double? uploadProgress;
  final void Function(int index) onRemove;

  const PendingFilesBar({
    super.key,
    required this.files,
    required this.uploadProgress,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (uploadProgress != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: LinearProgressIndicator(value: uploadProgress),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < files.length; i++)
                Chip(
                  avatar: const Icon(Icons.attach_file, size: 14),
                  label: Text(
                    files[i].fileName,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onDeleted: () => onRemove(i),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------------- interactions

class ChatInputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool sending;

  /// Pending attachments count as input for the send button's enabled
  /// state (text is tracked internally via the controller).
  final bool hasAttachments;
  final bool isDraft;
  final ConversationState? state;
  final WorkspacePrep? prep;
  final Map<String, String>? draftConfig;
  final ChatGateway gateway;
  final String? sessionId;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onSkills;
  final VoidCallback? onHistory;
  final VoidCallback onModelSheet;
  final VoidCallback onUsage;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.sending,
    required this.hasAttachments,
    required this.isDraft,
    required this.state,
    required this.prep,
    required this.draftConfig,
    required this.gateway,
    required this.sessionId,
    required this.onSend,
    required this.onAttach,
    required this.onSkills,
    this.onHistory,
    required this.onModelSheet,
    required this.onUsage,
  });

  @override
  State<ChatInputBar> createState() => _InputBarState();
}

class _InputBarState extends State<ChatInputBar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onText() {
    if (mounted) setState(() {});
  }

  bool get _hasInput =>
      widget.controller.text.trim().isNotEmpty || widget.hasAttachments;

  // Field forwarders so the build/helpers below read like the original
  // stateless widget.
  TextEditingController get controller => widget.controller;
  bool get sending => widget.sending;
  bool get isDraft => widget.isDraft;
  ConversationState? get state => widget.state;
  WorkspacePrep? get prep => widget.prep;
  Map<String, String>? get draftConfig => widget.draftConfig;
  ChatGateway get gateway => widget.gateway;
  String? get sessionId => widget.sessionId;
  VoidCallback get onSend => widget.onSend;
  VoidCallback get onAttach => widget.onAttach;
  VoidCallback get onSkills => widget.onSkills;
  VoidCallback? get onHistory => widget.onHistory;
  VoidCallback get onModelSheet => widget.onModelSheet;
  VoidCallback get onUsage => widget.onUsage;

  String get _modeValue => isDraft
      ? (draftConfig?['mode'] ?? 'build')
      : (state?.currentMode ?? 'build');

  String get _modelLabel {
    if (isDraft) {
      final v = draftConfig?['model'];
      if (v != null && v.isNotEmpty) {
        final idx = v.lastIndexOf('/');
        return idx > 0 ? v.substring(idx + 1) : v;
      }
      final current = prep?.option('model')?.currentValue;
      if (current != null && '$current'.isNotEmpty) {
        final idx = '$current'.lastIndexOf('/');
        return idx > 0 ? '$current'.substring(idx + 1) : '$current';
      }
      return '';
    }
    final model = state?.currentModel ?? '';
    if (model.isEmpty) return '';
    // Friendly option name from workspace prep when available.
    for (final o
        in prep?.option('model')?.options ?? const <ConfigOptionValue>[]) {
      if (o.value == model) return o.name;
    }
    final idx = model.lastIndexOf('/');
    return idx > 0 ? model.substring(idx + 1) : model;
  }

  String get _thoughtLabel {
    final raw = isDraft
        ? (draftConfig?['thought'] ??
            '${prep?.option('thought_level')?.currentValue ?? ''}')
        : (state?.currentThought ?? '');
    if (raw.isEmpty) return '';
    // Friendly option name (低/高/最高) when prep knows the value.
    for (final o in prep?.option('thought_level')?.options ??
        const <ConfigOptionValue>[]) {
      if (o.value == raw) return o.name;
    }
    return raw;
  }

  double? get _usageRatio {
    final window = state?.usage?['contextWindow'];
    if (window is! Map) return null;
    final used = (window['usedTokens'] as num?)?.toInt();
    final max = (window['maxTokens'] as num?)?.toInt();
    if (used == null || max == null || max <= 0) return null;
    return (used / max).clamp(0.0, 1.0);
  }

  List<String> get _thoughtChoices {
    final fromPrep =
        prep?.option('thought_level')?.options.map((o) => o.value).toList() ??
            const <String>[];
    return fromPrep.isNotEmpty ? fromPrep : (state?.thoughtLevels ?? const []);
  }

  @override
  Widget build(BuildContext context) {
    final running = state?.isRunning ?? false;
    // Official composer: icon-only buttons below sm (640), icon+label above.
    final wide = MediaQuery.sizeOf(context).width >= 640;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          decoration: BoxDecoration(
            color: ZInk.card(context),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: ZInk.hairline(context)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                minLines: 1,
                maxLines: 6,
                style: TextStyle(fontSize: 14, color: ZInk.solid(context)),
                decoration: InputDecoration(
                  hintText: tr(context, 'chat.input.hint'),
                  hintStyle: TextStyle(color: ZInk.ghost(context)),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                textInputAction: TextInputAction.newline,
              ),
              Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.add_circle_outline,
                      size: 20,
                      color: ZInk.muted(context),
                    ),
                    tooltip: tr(context, 'chat.input.attach'),
                    onPressed: sending ? null : onAttach,
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.auto_awesome_outlined,
                      size: 20,
                      color: ZInk.muted(context),
                    ),
                    tooltip: tr(context, 'chat.input.skills'),
                    onPressed: sending ? null : onSkills,
                  ),
                  if (!_hasInput && onHistory != null)
                    IconButton(
                      icon: Icon(
                        Icons.history,
                        size: 20,
                        color: ZInk.muted(context),
                      ),
                      tooltip: tr(context, 'chat.history.tooltip'),
                      onPressed: sending ? null : onHistory,
                    ),
                  _ControlChip(
                    label: tr(context, 'chat.mode.$_modeValue'),
                    icon: Icons.tune,
                    onTap: () => _pickMode(context),
                    showLabel: wide,
                  ),
                  const Spacer(),
                  if (_usageRatio != null)
                    _UsageRing(ratio: _usageRatio!, onTap: onUsage),
                  if (_modelLabel.isNotEmpty)
                    _ControlChip(
                      label: _modelLabel,
                      icon: Icons.memory_outlined,
                      onTap: onModelSheet,
                      showLabel: wide,
                    ),
                  if (_thoughtLabel.isNotEmpty)
                    _ControlChip(
                      label: _thoughtLabel,
                      icon: Icons.psychology_alt_outlined,
                      onTap: () => _pickThought(context),
                      showLabel: wide,
                    ),
                  const SizedBox(width: 4),
                  // Official composer state machine (web
                  // ConversationComposer): streaming + EMPTY draft → Stop;
                  // typed draft → Send (the follow-up enqueues and its bar
                  // carries the send-now choice).
                  if (running && !_hasInput)
                    _StopButton(onStop: () => _stop(context))
                  else
                    _SendButton(
                      enabled: _hasInput && !sending,
                      sending: sending,
                      onSend: onSend,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Official composer mode control (web V4ComposerModeControls): the chip
  /// opens a dropdown-style dialog with the full mode radio list.
  Future<void> _pickMode(BuildContext context) async {
    final sid = sessionId;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr(context, 'chat.sheet.mode')),
        children: [
          Column(
            children: [
              for (final m in const ['build', 'edit', 'plan', 'yolo'])
                RadioListTile<String>(
                  dense: true,
                  groupValue: _modeValue,
                  value: m,
                  onChanged: (v) => Navigator.pop(context, v ?? _modeValue),
                  title: Text(tr(context, 'chat.mode.$m')),
                  subtitle: Text(tr(context, 'chat.mode.$m.desc')),
                ),
            ],
          ),
        ],
      ),
    );
    if (value == null || value == _modeValue) return;
    if (isDraft || sid == null) return; // draft chips go through the sheet
    gateway.switchCollaborationMode(sid, value);
  }

  Future<void> _pickThought(BuildContext context) async {
    final sid = sessionId;
    final choices = _thoughtChoices;
    if (choices.isEmpty) {
      onModelSheet();
      return;
    }
    final value = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr(context, 'chat.sheet.thought')),
        children: [
          Column(
            children: [
              for (final t in choices)
                RadioListTile<String>(
                  dense: true,
                  groupValue: _thoughtLabel,
                  value: t,
                  onChanged: (v) => Navigator.pop(context, v ?? _thoughtLabel),
                  title: Text(t),
                ),
            ],
          ),
        ],
      ),
    );
    if (value == null || value == _thoughtLabel) return;
    if (isDraft || sid == null) return; // draft chips go through the sheet
    final modelValue =
        '${state?.config?['provider'] ?? ''}/${state?.config?['model'] ?? ''}';
    final idx = modelValue.lastIndexOf('/');
    gateway.switchModelConfig(
      sid,
      provider: idx > 0 ? modelValue.substring(0, idx) : modelValue,
      model: idx > 0 ? modelValue.substring(idx + 1) : modelValue,
      thought: value,
    );
  }

  void _stop(BuildContext context) {
    final sid = sessionId;
    if (sid == null) return;
    gateway.stop(sid);
  }
}

class _ControlChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// Official mobile parity: below the sm breakpoint the composer controls
  /// are icon-only 28×28 buttons; labels appear on wider layouts.
  final bool showLabel;

  const _ControlChip({
    required this.label,
    required this.icon,
    required this.onTap,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!showLabel) {
      return InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 16, color: ZInk.muted(context)),
        ),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: ZInk.tile(context),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: ZInk.muted(context)),
            const SizedBox(width: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: ZInk.soft(context)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Circular context-usage indicator (official 环形用量).
class _UsageRing extends StatelessWidget {
  final double ratio;
  final VoidCallback onTap;

  const _UsageRing({required this.ratio, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = ratio > 0.8 ? ZColors.warning : ZColors.sky500;
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(),
      tooltip: tr(context, 'chat.more.usage'),
      onPressed: onTap,
      icon: SizedBox(
        width: 18,
        height: 18,
        child: CustomPaint(
          painter: _RingPainter(ratio: ratio, color: color),
          child: Center(
            child: Text(
              '${(ratio * 100).round()}',
              style: TextStyle(
                fontSize: 6.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double ratio;
  final Color color;

  _RingPainter({required this.ratio, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.14;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    // background ring
    canvas.drawArc(
      rect.deflate(stroke / 2),
      0,
      2 * 3.1415926,
      false,
      paint..color = color.withValues(alpha: 0.2),
    );
    // value arc
    canvas.drawArc(
      rect.deflate(stroke / 2),
      -3.1415926 / 2,
      2 * 3.1415926 * ratio,
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.ratio != ratio || old.color != color;
}

class _SendButton extends StatelessWidget {
  final bool enabled;
  final bool sending;
  final VoidCallback onSend;

  const _SendButton({
    required this.enabled,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: enabled ? ZColors.sky500 : ZColors.sky500.withValues(alpha: 0.4),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: enabled ? onSend : null,
        icon: sending
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(
                Icons.arrow_upward,
                size: 18,
                color: enabled
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.7),
              ),
      ),
    );
  }
}

class _StopButton extends StatelessWidget {
  final VoidCallback onStop;

  const _StopButton({required this.onStop});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ZColors.danger.withValues(alpha: 0.2),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        tooltip: tr(context, 'tasks.stop'),
        onPressed: onStop,
        icon: const Icon(Icons.stop, color: ZColors.danger, size: 20),
      ),
    );
  }
}
