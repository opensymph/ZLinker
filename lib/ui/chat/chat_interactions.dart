import 'package:flutter/material.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'markdown_view.dart';

/// Pending-interaction cards: plan approval (ExitPlanMode), workspace hook
/// trust review, permission prompts and elicitation forms. Split out of
/// chat_page.dart for size.

class PendingInteractions extends StatelessWidget {
  final ConversationState state;
  final ChatGateway gateway;

  const PendingInteractions(
      {super.key, required this.state, required this.gateway});

  @override
  Widget build(BuildContext context) {
    final interactions = state.pendingInteractions;
    if (interactions.isEmpty) return const SizedBox.shrink();
    final sessionId = state.snapshot?['sessionId'] as String? ?? '';
    return Column(
      children: [
        for (final interaction in interactions)
          if (interaction['payload'] is Map &&
              _isPlanApprovalPayload(
                interaction['payload'] as Map,
              ))
            _PlanApprovalCard(
              interaction: interaction,
              onResolve: ({optionId, freeText, action, content}) =>
                  gateway.resolveInteraction(
                sessionId,
                interaction['interactionId'] as String? ?? '',
                optionId: optionId,
                freeText: freeText,
                action: action,
                content: content,
              ),
            )
          else if (interaction['payload'] is Map &&
              interaction['payload']['kind'] == 'workspaceHookReview')
            _HookReviewCard(
              interaction: interaction,
              onTrust: (reviewItemIds) => gateway.respondWorkspaceHookReview(
                sessionId,
                interaction['payload'] as Map,
                reviewItemIds,
              ),
            )
          else
            _InteractionCard(
              interaction: interaction,
              onResolve: ({optionId, freeText, action, content}) =>
                  gateway.resolveInteraction(
                sessionId,
                interaction['interactionId'] as String? ?? '',
                optionId: optionId,
                freeText: freeText,
                action: action,
                content: content,
              ),
              onSnooze: () => gateway.snoozeInteraction(
                sessionId,
                interaction['interactionId'] as String? ?? '',
              ),
            ),
      ],
    );
  }
}

/// Plan approval rides the userInput channel (web isExitPlanMode): detected
/// via payload.toolName or the schema marker written by the CLI projection.
bool _isPlanApprovalPayload(Map payload) {
  if (payload['kind'] != 'userInput') return false;
  final tool = '${payload['toolName'] ?? ''}'.trim().toLowerCase();
  if (tool == 'exitplanmode') return true;
  final schema = payload['schema'];
  return schema is Map &&
      schema['interaction'] == 'plan_approval' &&
      '${schema['toolName'] ?? ''}'.toLowerCase() == 'exitplanmode';
}

/// Mirrors the web client's buildElicitationResponseContent: `answers` maps
/// question → values joined with ", ", `answer_N` carries per-question
/// values (an array under multiSelect), plus the legacy single-question
/// `answer` field. Questions without answers are omitted entirely — empty
/// partial answers let the agent continue with best judgment.
Map<String, dynamic> _buildElicitationContent(
  List<Map> questions,
  List<List<String>> answersPerQuestion,
) {
  final answers = <String, String>{};
  final content = <String, dynamic>{};
  for (var i = 0; i < questions.length; i++) {
    final values = answersPerQuestion[i];
    if (values.isEmpty) continue;
    final question = '${questions[i]['question'] ?? ''}';
    final multi = questions[i]['multiSelect'] == true;
    answers[question] = values.join(', ');
    content['answer_$i'] = multi ? List<String>.of(values) : values.first;
  }
  content['answers'] = answers;
  if (questions.length == 1 && answersPerQuestion.isNotEmpty) {
    final values = answersPerQuestion.first;
    if (values.isNotEmpty) {
      final multi = questions.first['multiSelect'] == true;
      content['answer'] = multi ? List<String>.of(values) : values.first;
    }
  }
  return content;
}

class _InteractionCard extends StatefulWidget {
  final Map<String, dynamic> interaction;
  final Future<dynamic> Function({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) onResolve;

  /// Defers the auto-resolution timer (web snoozeInteractionAutoResolution,
  /// desktop setting「提问自动继续」).
  final Future<void> Function()? onSnooze;

  const _InteractionCard({
    required this.interaction,
    required this.onResolve,
    this.onSnooze,
  });

  @override
  State<_InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<_InteractionCard> {
  final _freeTextController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _freeTextController.dispose();
    super.dispose();
  }

  Future<void> _resolve({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onResolve(
        optionId: optionId,
        freeText: freeText,
        action: action,
        content: content,
      );
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.interaction['payload'];
    if (payload is! Map) return const SizedBox.shrink();
    final kind = payload['kind'];
    final options = payload['options'];
    final questions = payload['questions'];
    final freeText = payload['freeText'] == true;

    final title = kind == 'permission'
        ? trP(context, 'chat.interact.permission', [
            '${payload['toolName'] ?? ''}',
          ])
        : tr(context, 'chat.interact.waiting');

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.privacy_tip_outlined,
                size: 14,
                color: ZColors.warning,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
                ),
              ),
            ],
          ),
          if (kind == 'userInput' &&
              (payload['prompt'] as String? ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${payload['prompt']}',
                style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
              ),
            ),
          if (kind == 'permission' && payload['summary'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${payload['summary']}',
                style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
              ),
            ),
          const SizedBox(height: 8),
          if (options is List && options.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in options)
                  if (option is Map)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        minimumSize: Size.zero,
                      ),
                      onPressed: _busy
                          ? null
                          : () => _resolve(optionId: '${option['optionId']}'),
                      child: Text(
                        _optionLabel(option),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
              ],
            ),
          if (questions is List && questions.isNotEmpty)
            _ElicitationForm(
              questions: questions.cast<Map>(),
              sensitive: payload['sensitive'] == true,
              busy: _busy,
              onSubmit: (content) =>
                  _resolve(action: 'accept', content: content),
              onCancel: () => _resolve(action: 'decline'),
            ),
          if (freeText)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _freeTextController,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: tr(context, 'chat.interact.hint'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send, size: 18),
                  onPressed: _busy
                      ? null
                      : () =>
                          _resolve(freeText: _freeTextController.text.trim()),
                ),
              ],
            ),
          if (widget.onSnooze != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _busy ? null : () => widget.onSnooze!(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.snooze_outlined,
                          size: 12,
                          color: ZInk.muted(context),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          tr(context, 'chat.interact.snooze'),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: ZInk.muted(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _optionLabel(Map option) {
    final label = option['label'] as String?;
    if (label != null && label.isNotEmpty) return label;
    final kind = option['kind'] as String?;
    return switch (kind) {
      'allowOnce' => tr(context, 'chat.interact.allowOnce'),
      'allowAlways' => tr(context, 'chat.interact.allowAlways'),
      'deny' => tr(context, 'chat.interact.deny'),
      'custom' => tr(context, 'chat.interact.custom'),
      _ => '${option['optionId'] ?? tr(context, 'chat.interact.pick')}',
    };
  }
}

/// ExitPlanMode approval rides the userInput channel too. Approval and
/// feedback both resolve with `accept`: the CLI broker reads the answer and
/// treats "approve" as allow, any other text as deny-with-reason
/// (plan_approval_feedback); plain `decline` denies without a reason.
class _PlanApprovalCard extends StatefulWidget {
  final Map interaction;
  final Future<dynamic> Function({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) onResolve;

  const _PlanApprovalCard({
    required this.interaction,
    required this.onResolve,
  });

  @override
  State<_PlanApprovalCard> createState() => _PlanApprovalCardState();
}

class _PlanApprovalCardState extends State<_PlanApprovalCard> {
  final _feedbackController = TextEditingController();
  bool _busy = false;
  bool _planExpanded = true;

  @override
  void dispose() {
    _feedbackController.dispose();
    super.dispose();
  }

  Map get _payload => widget.interaction['payload'] as Map;

  /// The approval question text (the CLI projects the plan reason into it).
  String get _question {
    final questions = _payload['questions'];
    if (questions is List && questions.isNotEmpty) {
      return '${questions.first['question'] ?? ''}';
    }
    return '${_payload['prompt'] ?? ''}';
  }

  String get _planMarkdown {
    final input = _payload['input'];
    if (input is Map) return '${input['plan'] ?? ''}';
    return '';
  }

  Future<void> _resolve({
    String? action,
    Map<String, dynamic>? content,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onResolve(action: action, content: content);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Approve: answer = "approve" (the web continueOrSubmit auto-select
  /// path). Typed feedback stays in its field and is not sent along.
  void _approve() {
    _resolve(
      action: 'accept',
      content: _buildElicitationContent([
        {'question': _question},
      ], [
        ['approve'],
      ]),
    );
  }

  /// Decline: with feedback this sends accept + the feedback text (the
  /// broker normalizes it to deny + plan_approval_feedback); without, a
  /// plain decline.
  void _decline() {
    final feedback = _feedbackController.text.trim();
    if (feedback.isEmpty) {
      _resolve(action: 'decline');
      return;
    }
    _resolve(
      action: 'accept',
      content: _buildElicitationContent([
        {'question': _question},
      ], [
        [feedback],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = _planMarkdown;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZColors.sky500.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.sky500.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.fact_check_outlined,
                size: 14,
                color: ZColors.sky500,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tr(context, 'chat.interact.plan.title'),
                  style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
                ),
              ),
            ],
          ),
          if (plan.isNotEmpty) ...[
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() => _planExpanded = !_planExpanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _planExpanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 14,
                      color: ZInk.muted(context),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      tr(context, 'chat.interact.plan.viewPlan'),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: ZInk.muted(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_planExpanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: SingleChildScrollView(
                  child: ZLinkerMarkdown(plan, fontSize: 13),
                ),
              ),
          ],
          const SizedBox(height: 6),
          TextField(
            controller: _feedbackController,
            enabled: !_busy,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: tr(context, 'chat.interact.plan.feedback'),
              hintStyle: TextStyle(fontSize: 12, color: ZInk.ghost(context)),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: ZInk.hairline(context)),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: ZColors.sky500,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    minimumSize: Size.zero,
                  ),
                  onPressed: _busy ? null : _approve,
                  child: Text(
                    tr(context, 'chat.interact.plan.approve'),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    minimumSize: Size.zero,
                  ),
                  onPressed: _busy ? null : _decline,
                  child: Text(
                    tr(context, 'chat.interact.plan.decline'),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Workspace hook trust review (web WorkspaceHookPendingBanner): lists the
/// hooks the workspace wants to run and trusts the selected ones via the
/// dedicated respondWorkspaceHookReview command — the only decision the
/// protocol offers.
class _HookReviewCard extends StatefulWidget {
  final Map interaction;
  final Future<void> Function(List<String> reviewItemIds) onTrust;

  const _HookReviewCard({required this.interaction, required this.onTrust});

  @override
  State<_HookReviewCard> createState() => _HookReviewCardState();
}

class _HookReviewCardState extends State<_HookReviewCard> {
  late final Set<String> _checked;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final payload = widget.interaction['payload'];
    final items = payload is Map ? payload['items'] : null;
    _checked = {
      if (items is List)
        for (final item in items)
          if (item is Map && item['reviewItemId'] != null)
            '${item['reviewItemId']}',
    };
  }

  List<Map> get _items {
    final payload = widget.interaction['payload'];
    final items = payload is Map ? payload['items'] : null;
    return items is List ? items.whereType<Map>().toList() : const <Map>[];
  }

  Future<void> _trust() async {
    if (_busy || _checked.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.onTrust(_checked.toList());
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final payload = widget.interaction['payload'];
    final label = payload is Map ? '${payload['workspaceLabel'] ?? ''}' : '';
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.shield_outlined,
                size: 14,
                color: ZColors.warning,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tr(context, 'chat.interact.hook.title'),
                  style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              tr(context, 'chat.interact.hook.warning'),
              style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
            ),
          ),
          if (label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
              ),
            ),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: _checked.contains('${item['reviewItemId']}'),
                      onChanged: _busy
                          ? null
                          : (on) => setState(() {
                                final id = '${item['reviewItemId']}';
                                if (on == true) {
                                  _checked.add(id);
                                } else {
                                  _checked.remove(id);
                                }
                              }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${item['displayName'] ?? ''}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: ZInk.solid(context),
                          ),
                        ),
                        if (item['displayCommand'] != null)
                          Text(
                            '${item['displayCommand']}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontFamily: 'monospace',
                              color: ZInk.faint(context),
                            ),
                          ),
                        if (item['event'] != null)
                          Text(
                            '${item['event']}',
                            style: TextStyle(
                              fontSize: 10,
                              color: ZInk.faint(context),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                tr(context, 'chat.interact.hook.empty'),
                style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: ZColors.warning,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
              ),
              onPressed: _busy || _checked.isEmpty ? null : _trust,
              child: Text(
                tr(context, 'chat.interact.hook.trust'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Form-style `userInput` (elicitation) card body: every question at once,
/// options as chips, an optional custom answer per question. Submit builds
/// the web client's buildElicitationResponseContent shape.
class _ElicitationForm extends StatefulWidget {
  final List<Map> questions;

  /// Payload-level `sensitive` (the request carries a secret).
  final bool sensitive;
  final bool busy;
  final void Function(Map<String, dynamic> content) onSubmit;
  final VoidCallback onCancel;

  const _ElicitationForm({
    required this.questions,
    required this.sensitive,
    required this.busy,
    required this.onSubmit,
    required this.onCancel,
  });

  @override
  State<_ElicitationForm> createState() => _ElicitationFormState();
}

class _ElicitationFormState extends State<_ElicitationForm> {
  late final List<Set<String>> _selected;
  late final List<TextEditingController> _custom;

  @override
  void initState() {
    super.initState();
    _selected = List.generate(widget.questions.length, (_) => <String>{});
    _custom = List.generate(
      widget.questions.length,
      (_) => TextEditingController(),
    );
  }

  @override
  void dispose() {
    for (final controller in _custom) {
      controller.dispose();
    }
    super.dispose();
  }

  List<List<String>> get _answers => [
        for (var i = 0; i < widget.questions.length; i++)
          [
            ..._selected[i],
            if (_custom[i].text.trim().isNotEmpty) _custom[i].text.trim(),
          ],
      ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widget.questions.length; i++)
          _ElicitationQuestionItem(
            index: i,
            question: widget.questions[i],
            selected: _selected[i],
            customController: _custom[i],
            sensitive: widget.sensitive,
            busy: widget.busy,
            onToggle: (value) {
              setState(() {
                // Single-choice replaces the selection; re-tapping the
                // picked chip clears it. Empty answers are allowed — the
                // agent continues with best judgment.
                if (widget.questions[i]['multiSelect'] != true) {
                  _selected[i].clear();
                }
                if (!_selected[i].add(value)) _selected[i].remove(value);
              });
            },
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: widget.busy ? null : widget.onCancel,
              child: Text(
                tr(context, 'chat.interact.form.cancel'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
              ),
              onPressed: widget.busy
                  ? null
                  : () => widget.onSubmit(
                        _buildElicitationContent(
                          widget.questions,
                          _answers,
                        ),
                      ),
              child: Text(
                tr(context, 'chat.interact.form.submit'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ElicitationQuestionItem extends StatelessWidget {
  final int index;
  final Map question;
  final Set<String> selected;
  final TextEditingController customController;
  final bool sensitive;
  final bool busy;
  final void Function(String value) onToggle;

  const _ElicitationQuestionItem({
    required this.index,
    required this.question,
    required this.selected,
    required this.customController,
    required this.sensitive,
    required this.busy,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final q = question;
    final header = q['header'] ?? q['question'] ?? '';
    final options = q['options'];
    final multi = q['multiSelect'] == true;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${index + 1}. $header',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: ZInk.solid(context),
                  ),
                ),
              ),
              if (multi)
                Text(
                  tr(context, 'chat.interact.form.multi'),
                  style: TextStyle(
                    fontSize: 10,
                    color: ZInk.faint(context),
                  ),
                ),
            ],
          ),
          if (q['description'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${q['description']}',
                style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
              ),
            ),
          if (options is List && options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final o in options)
                    if (o is Map)
                      FilterChip(
                        label: Text(
                          '${o['label'] ?? o['value'] ?? ''}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: selected.contains('${o['value']}'),
                        onSelected:
                            busy ? null : (_) => onToggle('${o['value']}'),
                      ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextField(
              controller: customController,
              enabled: !busy,
              obscureText: sensitive,
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                hintText: tr(context, 'chat.interact.form.custom'),
                hintStyle: TextStyle(
                  fontSize: 11.5,
                  color: ZInk.ghost(context),
                ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: ZInk.hairline(context)),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------------- sheets
