import 'package:flutter/material.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';

/// Bottom sheets for the chat page: model/mode/thought picker, usage
/// stats, slash-command bar and the skills picker. Split out of
/// chat_page.dart for size.

class ModelModeSheet extends StatelessWidget {
  final ChatGateway gateway;
  final ConversationState? state;
  final WorkspacePrep? prep;
  final String? sessionId;
  final Map<String, String>? draftConfig;
  final void Function(String key, String value)? onDraftChange;

  const ModelModeSheet({
    super.key,
    required this.gateway,
    required this.state,
    required this.prep,
    required this.sessionId,
    this.draftConfig,
    this.onDraftChange,
  });

  bool get _isDraft => sessionId == null || sessionId!.isEmpty;

  /// Config options beyond the model/mode/thought selects (e.g. max output
  /// length, search enhancement) surfaced read-only from prepareWorkspace.
  List<ConfigOption> get _otherOptions {
    const known = {'model', 'mode', 'thought_level'};
    final options = prep?.configOptions;
    if (options == null) return const [];
    return options.where((o) => !known.contains(o.id)).toList();
  }

  /// 'builtin:zai-coding-plan/GLM-5.2' → (provider, model)
  (String, String) _splitModelValue(String value) {
    final idx = value.lastIndexOf('/');
    if (idx <= 0) return (value, value);
    return (value.substring(0, idx), value.substring(idx + 1));
  }

  @override
  Widget build(BuildContext context) {
    final sid = sessionId ?? '';
    final config = state?.config ?? const {};
    final modelOption = prep?.option('model');
    final modeOption = prep?.option('mode');
    final thoughtOption = prep?.option('thought_level');
    final followup = '${config['followupMode'] ?? 'queue'}';

    // Current selection: prefer the LIVE session config (updates after a
    // switch), fall back to prepareWorkspace's currentValue / draft.
    final liveModelValue =
        '${config['provider'] ?? ''}/${config['model'] ?? ''}';
    final currentModelValue =
        _isDraft || config['model'] == null || '${config['model']}'.isEmpty
            ? (draftConfig?['model'] ?? '${modelOption?.currentValue ?? ''}')
            : liveModelValue;
    final currentThoughtValue = _isDraft
        ? (draftConfig?['thought'] ?? '${thoughtOption?.currentValue ?? ''}')
        : (state?.currentThought.isNotEmpty == true
            ? state!.currentThought
            : '${thoughtOption?.currentValue ?? ''}');
    final currentModeValue = _isDraft
        ? (draftConfig?['mode'] ?? 'build')
        : state?.currentMode ?? 'build';

    // Bare model ids (single-provider) match the session's config model.
    bool modelSelected(String value) {
      if (currentModelValue == value) return true;
      final cfgModel = '${config['model'] ?? ''}';
      return cfgModel.isNotEmpty &&
          (cfgModel == value || value.endsWith('/$cfgModel'));
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isDraft
                  ? tr(context, 'chat.sheet.draftTitle')
                  : tr(context, 'chat.sheet.title'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            if (modelOption != null && modelOption.options.isNotEmpty) ...[
              Text(
                modelOption.name,
                style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              // Official web menu groups models by provider (BigModel /
              // tx / kimi_zz …): header whenever the provider changes.
              for (final (i, v) in modelOption.options.indexed) ...[
                if (i == 0 ||
                    v.modelProviderName !=
                        modelOption.options[i - 1].modelProviderName)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 10, bottom: 2),
                    child: Text(
                      v.modelProviderName ?? v.name,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: ZInk.ghost(context),
                      ),
                    ),
                  ),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    modelSelected(v.value)
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: modelSelected(v.value)
                        ? ZColors.sky500
                        : ZInk.ghost(context),
                  ),
                  title: Text(
                    v.name,
                    style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
                  ),
                  subtitle: v.modelProviderName != null
                      ? Text(
                          v.modelProviderName!,
                          style: TextStyle(
                            fontSize: 11,
                            color: ZInk.faint(context),
                          ),
                        )
                      : null,
                  onTap: () {
                    if (_isDraft) {
                      onDraftChange?.call('model', v.value);
                    } else {
                      // Single-provider setups (e.g. glm) list BARE model
                      // ids without a provider prefix — keep the session's
                      // current provider instead of echoing the model twice.
                      final (rawProvider, model) = _splitModelValue(v.value);
                      final provider = v.value.contains('/')
                          ? rawProvider
                          : '${config['provider'] ?? rawProvider}';
                      // thought must be valid for the target model:
                      // keep current if supported, else fall back to the
                      // thought option's currentValue.
                      final currentThought = state?.currentThought ?? '';
                      final thoughtOpt = prep?.option('thought_level');
                      final thought = currentThought.isNotEmpty &&
                              (thoughtOpt?.options.any(
                                    (o) => o.value == currentThought,
                                  ) ??
                                  false)
                          ? currentThought
                          : '${thoughtOpt?.currentValue ?? (currentThought.isNotEmpty ? currentThought : 'enabled')}';
                      _apply(
                        context,
                        () => gateway.switchModelConfig(
                          sid,
                          provider: provider,
                          model: model,
                          thought: thought,
                        ),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {
                            ...?state!.config,
                            'provider': provider,
                            'model': model,
                            'thought': thought,
                          },
                        }),
                      );
                    }
                  },
                ),
              ],
              const SizedBox(height: 12),
            ] else
              Text(
                trP(context, 'chat.sheet.currentModel', [
                  state?.currentModel ?? '',
                ]),
                style: TextStyle(fontSize: 12, color: ZInk.muted(context)),
              ),
            if (thoughtOption != null && thoughtOption.options.isNotEmpty) ...[
              Text(
                thoughtOption.name,
                style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in thoughtOption.options)
                    ChoiceChip(
                      label: Text(v.name),
                      selected: currentThoughtValue == v.value ||
                          state?.currentThought == v.value,
                      onSelected: (_) {
                        if (_isDraft) {
                          onDraftChange?.call('thought', v.value);
                        } else {
                          final modelValue = currentModelValue;
                          final (provider, model) = modelValue.isNotEmpty
                              ? _splitModelValue(modelValue)
                              : (
                                  '${config['provider'] ?? ''}',
                                  '${config['model'] ?? ''}',
                                );
                          _apply(
                            context,
                            () => gateway.switchModelConfig(
                              sid,
                              provider: provider,
                              model: model,
                              thought: v.value,
                            ),
                            onAccepted: () => state?.optimisticPatch({
                              'config': {...?state!.config, 'thought': v.value},
                            }),
                          );
                        }
                      },
                    ),
                ],
              ),
            ] else if ((state?.thoughtLevels ?? const []).isNotEmpty) ...[
              Text(
                tr(context, 'chat.sheet.thought'),
                style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final level in state!.thoughtLevels)
                    ChoiceChip(
                      label: Text(level),
                      selected: state?.currentThought == level,
                      onSelected: (_) => _apply(
                        context,
                        () => gateway.switchModelConfig(
                          sid,
                          provider: '${config['provider'] ?? ''}',
                          model: '${config['model'] ?? ''}',
                          thought: level,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text(
              tr(context, 'chat.sheet.mode'),
              style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
            ),
            const SizedBox(height: 8),
            if (modeOption != null && modeOption.options.isNotEmpty)
              for (final v in modeOption.options)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    currentModeValue == v.value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: currentModeValue == v.value
                        ? ZColors.sky500
                        : ZInk.ghost(context),
                  ),
                  title: Text(
                    v.name,
                    style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
                  ),
                  subtitle: v.description != null
                      ? Text(
                          v.description!,
                          style: TextStyle(
                            fontSize: 11,
                            color: ZInk.faint(context),
                          ),
                        )
                      : null,
                  onTap: () {
                    if (_isDraft) {
                      onDraftChange?.call('mode', v.value);
                    } else {
                      _apply(
                        context,
                        () => gateway.switchCollaborationMode(sid, v.value),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {...?state!.config, 'mode': v.value},
                        }),
                      );
                    }
                  },
                )
            else
              for (final m in const ['build', 'edit', 'plan', 'yolo'])
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    currentModeValue == m
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: currentModeValue == m
                        ? ZColors.sky500
                        : ZInk.ghost(context),
                  ),
                  title: Text(
                    tr(context, 'chat.mode.$m'),
                    style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
                  ),
                  subtitle: Text(
                    tr(context, 'chat.mode.$m.desc'),
                    style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                  ),
                  onTap: () {
                    if (_isDraft) {
                      onDraftChange?.call('mode', m);
                    } else {
                      _apply(
                        context,
                        () => gateway.switchCollaborationMode(sid, m),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {...?state!.config, 'mode': m},
                        }),
                      );
                    }
                  },
                ),
            if (!_isDraft) ...[
              const SizedBox(height: 16),
              Text(
                tr(context, 'chat.sheet.followup'),
                style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final f in const ['queue', 'guide'])
                    ChoiceChip(
                      label: Text(
                        f == 'queue'
                            ? tr(context, 'chat.followup.queue')
                            : tr(context, 'chat.followup.guide'),
                      ),
                      selected: followup == f,
                      onSelected: (_) => _apply(
                        context,
                        () => gateway.setFollowupMode(sid, f),
                        onAccepted: () => state?.optimisticPatch({
                          'config': {...?state!.config, 'followupMode': f},
                        }),
                      ),
                    ),
                ],
              ),
            ],
            if (_otherOptions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                tr(context, 'chat.sheet.other'),
                style: TextStyle(fontSize: 13, color: ZInk.solid(context)),
              ),
              const SizedBox(height: 8),
              for (final o in _otherOptions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          o.name,
                          style: TextStyle(
                            fontSize: 13,
                            color: ZInk.solid(context),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${o.currentValue}',
                        style: TextStyle(
                          fontSize: 12,
                          color: ZInk.muted(context),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _apply(
    BuildContext context,
    Future<dynamic> Function() run, {
    void Function()? onAccepted,
  }) async {
    try {
      final res = await run();
      if (context.mounted) {
        if (res is Map &&
            res['status'] != null &&
            res['status'] != 'accepted') {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                trP(context, 'chat.sheet.rejected', [
                  '${res['reasonCode'] ?? res['status']}',
                ]),
              ),
            ),
          );
        } else {
          onAccepted?.call();
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trP(context, 'chat.op.failed', ['$e']))),
        );
      }
    }
  }
}

class UsageSheet extends StatelessWidget {
  final ConversationState state;

  const UsageSheet({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final usage = state.usage ?? const {};
    final cumulative = usage['cumulative'];
    final contextWindow = usage['contextWindow'];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(context, 'chat.more.usage'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            if (contextWindow is Map)
              _UsageRow(
                tr(context, 'chat.usage.context'),
                '${contextWindow['usedTokens'] ?? '-'} / ${contextWindow['maxTokens'] ?? '-'} tokens',
              ),
            if (cumulative is Map) ...[
              _UsageRow(
                tr(context, 'chat.usage.input'),
                '${cumulative['inputTokens'] ?? 0}',
              ),
              _UsageRow(
                tr(context, 'chat.usage.output'),
                '${cumulative['outputTokens'] ?? 0}',
              ),
              _UsageRow(
                tr(context, 'chat.usage.cacheRead'),
                '${cumulative['cacheReadTokens'] ?? 0}',
              ),
              _UsageRow(
                tr(context, 'chat.usage.cacheWrite'),
                '${cumulative['cacheWriteTokens'] ?? 0}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  final String label;
  final String value;

  const _UsageRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 13, color: ZInk.muted(context)),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------------- input

/// One entry in the slash popup: a builtin/custom command or a skill.
class SlashItem {
  final String name;
  final String description;
  final String insert;
  final bool isSkill;

  const SlashItem({
    required this.name,
    required this.description,
    required this.insert,
    this.isSkill = false,
  });
}

class SlashCommandBar extends StatelessWidget {
  final String query;
  final List<SlashItem> items;
  final void Function(SlashItem item) onSelect;

  const SlashCommandBar({
    super.key,
    required this.query,
    required this.items,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.startsWith('/') || query.startsWith('\$')
        ? query.substring(1)
        : query;
    final filtered = q.isEmpty
        ? items
        : items
            .where((c) => c.name.toLowerCase().startsWith(q.toLowerCase()))
            .toList();
    if (filtered.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: ZColors.darkCard,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          tr(context, 'chat.slash.empty'),
          style: TextStyle(fontSize: 12, color: ZInk.faint(context)),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: ZColors.darkCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ZInk.hairline(context)),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final command in filtered)
            ListTile(
              dense: true,
              leading: Icon(
                command.isSkill
                    ? Icons.auto_awesome_outlined
                    : (command.name == 'compact' ? Icons.compress : Icons.bolt),
                size: 16,
                color: command.isSkill ? ZColors.warning : ZColors.sky500,
              ),
              title: Text(
                command.isSkill ? '\$${command.name}' : '/${command.name}',
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
              subtitle: Text(
                command.description,
                style: TextStyle(fontSize: 11, color: ZInk.faint(context)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onSelect(command),
            ),
        ],
      ),
    );
  }
}

class SkillsPickerSheet extends StatelessWidget {
  final List<SkillEntry> skills;
  final bool loading;
  final void Function(SkillEntry skill) onSelect;
  final Future<void> Function() onRefresh;

  const SkillsPickerSheet({
    super.key,
    required this.skills,
    required this.loading,
    required this.onSelect,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final list = skills.where((s) => s.enabled).toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  tr(context, 'chat.skills.title'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    Icons.refresh,
                    size: 18,
                    color: ZInk.muted(context),
                  ),
                  tooltip: tr(context, 'tasks.retry'),
                  onPressed: onRefresh,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  tr(context, 'chat.skills.empty'),
                  style: TextStyle(fontSize: 13, color: ZInk.muted(context)),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in list)
                      ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.auto_awesome_outlined,
                          size: 18,
                          color: ZColors.warning,
                        ),
                        title: Text(
                          '\$${s.name}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontFamily: 'monospace',
                          ),
                        ),
                        subtitle: s.description != null
                            ? Text(
                                s.description!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: ZInk.faint(context),
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        onTap: () => onSelect(s),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Official composer: rounded container with the text field on top and a
/// control row underneath — left: add-context / mode chip; right: usage
/// ring, model chip, thought chip, send/stop button.
///
/// Stateful: listens to the text controller so the send button's
/// empty-input disabled state (official web) updates on every keystroke
/// without rebuilding the whole page.
