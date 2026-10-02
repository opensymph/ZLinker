import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/conversation.dart';
import '../protocol/off_peak.dart';
import '../state/device_session.dart';
import '../state/device_store.dart';
import 'chat/chat_page.dart';
import 'model_option_field.dart';
import 'remote_page.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Off-peak tasks (闲时任务) of one device: free queued runs executed in
/// compute-rich windows (Coding Plan only, monthly quota). Results open
/// the native chat page; the WebView stays as fallback.
class OffPeakPage extends StatefulWidget {
  final DeviceStore store;
  final DeviceSessionHub hub;
  final Device device;

  /// Test seam: overrides the hub-resolved device session.
  final OffPeakHost? hostOverride;
  const OffPeakPage({
    super.key,
    required this.store,
    required this.hub,
    required this.device,
    this.hostOverride,
  });

  @override
  State<OffPeakPage> createState() => _OffPeakPageState();
}

class _OffPeakPageState extends State<OffPeakPage>
    with SingleTickerProviderStateMixin {
  OffPeakHost? get _session =>
      widget.hostOverride ?? widget.hub.sessionOf(widget.device.id);

  List<OffPeakTask> _tasks = const [];
  OffPeakStatus? _status;

  /// Official model-selection view (providers/models) backing the form's
  /// model picker; empty when the desktop doesn't serve it.
  List<OffPeakModelChoice> _modelChoices = const [];
  bool _loading = true;
  String? _error;
  bool _busy = false;
  Timer? _refresh;
  late final TabController _tabs =
      TabController(length: 2, vsync: this, initialIndex: 0);
  bool _bannerDismissed = false;

  @override
  void initState() {
    super.initState();
    _load();
    // Queue position (排队位置) moves server-side; poll while visible.
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = _session;
    if (session == null || session.status != DeviceStatus.connected) {
      if (mounted) {
        setState(() {
          _loading = session != null &&
              session.status == DeviceStatus.connecting;
          _error = null;
        });
      }
      return;
    }
    try {
      final tasks = await session.offPeak.list();
      unawaited(session.offPeak.wake());
      final status = await session.offPeak.status();
      // Best-effort: the picker falls back to prepareWorkspace when the
      // desktop rejects the model-selection channel.
      final choices = await session.modelSelectionView();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _status = status;
        if (choices.isNotEmpty) _modelChoices = choices;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _runOp(Future<void> Function() op) async {
    if (_busy) return;
    _busy = true;
    try {
      await op();
    } on OffPeakError catch (e) {
      if (mounted) _toast(_offPeakErrorText(context, e));
    } catch (e) {
      if (mounted) _toast(trP(context, 'op.err.other', ['$e']));
    } finally {
      _busy = false;
    }
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Official error copy for the three known error states.
  String _offPeakErrorText(BuildContext context, OffPeakError e) =>
      switch (e.kind) {
        OffPeakError.codingPlanOnly => tr(context, 'op.err.codingPlanOnly'),
        OffPeakError.quota => tr(context, 'op.err.quota'),
        OffPeakError.unavailable => tr(context, 'op.err.unavailable'),
        _ => trP(context, 'op.err.other', [e.message]),
      };

  /// Desktop availability payload's `allowedModels` (plain names).
  List<String> get _allowedModels {
    final allowed = _status?.raw['allowedModels'];
    return allowed is List
        ? [for (final v in allowed) if (v is String) v]
        : const <String>[];
  }

  /// Desktop availability payload's `allowedModelConfigs` raw list, each
  /// entry carrying `{model?, reasoning: {levels[], defaultLevel?}}`.
  List<Map<String, dynamic>> get _allowedModelConfigs {
    final configs = _status?.raw['allowedModelConfigs'];
    return configs is List
        ? [for (final c in configs) if (c is Map) c.cast<String, dynamic>()]
        : const <Map<String, dynamic>>[];
  }

  Future<void> _showAddSheet() async {
    await _showSheet();
  }

  Future<void> _showSheet({OffPeakTask? editing}) async {
    final session = _session;
    if (session == null || session.status != DeviceStatus.connected) {
      _toast(tr(context, 'op.unavailable.title'));
      return;
    }
    // Desktop parity: model options come from the official model-selection
    // view (prepareWorkspace stays the fallback); thought options come from
    // the selected model's reasoning levels.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => OffPeakSheet(
        session: session,
        editing: editing,
        loadOptions:
            session is DeviceSession ? session.prepareWorkspace : null,
        allowedModels: _allowedModels.isEmpty ? null : _allowedModels,
        allowedModelConfigs: _allowedModelConfigs,
        modelChoices: _modelChoices,
      ),
    );
    await _load();
  }

  /// Result tap: native chat page deep-linked to the produced session (the
  /// protocol link stays live); WebView fallback when no link exists.
  Future<void> _openResult(OffPeakTask task) async {
    final sessionId = task.sessionId ?? task.conversationId;
    if (sessionId == null) return;
    await widget.store.touch(widget.device.id);
    final deviceSession = widget.hub.sessionOf(widget.device.id);
    if (!mounted) return;
    if (deviceSession != null) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatPage(
          gateway: deviceSession,
          sessionId: sessionId,
          title: task.title.isEmpty
              ? tr(context, 'op.viewResult')
              : task.title,
        ),
      ));
      return;
    }
    await widget.hub.suspend(widget.device.id);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RemotePage(
        device: widget.device,
        targetSessionId: sessionId,
        targetTitle: task.title.isEmpty ? null : task.title,
      ),
    ));
    widget.hub.scheduleResume(widget.device);
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.device.label,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            Text(tr(context, 'op.subtitle'),
                style: TextStyle(fontSize: 11, color: ZInk.faint(context))),
          ],
        ),
        actions: [
          IconButton(
            tooltip: tr(context, 'tasks.retry'),
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
        // Official two-pane layout: 设置 / 历史.
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: tr(context, 'op.tab.settings')),
            Tab(text: tr(context, 'op.tab.history')),
          ],
        ),
      ),
      floatingActionButton: _tabs.index == 0
          ? FloatingActionButton.extended(
              heroTag: 'offpeak-add',
              onPressed: _showAddSheet,
              icon: const Icon(Icons.add),
              label: Text(tr(context, 'op.add')),
            )
          : null,
      body: AnimatedBuilder(
        animation: Listenable.merge([widget.hub, _tabs]),
        builder: (context, _) {
          if (session == null ||
              session.status == DeviceStatus.disconnected ||
              session.status == DeviceStatus.error) {
            return _centerNote(context, tr(context, 'op.unavailable.title'),
                tr(context, 'op.unavailable.body'));
          }
          if (_loading && _tasks.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(tr(context, 'op.loading'),
                      style: TextStyle(
                          fontSize: 13, color: ZInk.faint(context))),
                ],
              ),
            );
          }
          final view =
              _tabs.index == 0 ? _settingsView(context) : _historyView(context);
          return RefreshIndicator(onRefresh: _load, child: view);
        },
      ),
    );
  }

  /// 设置 tab: subscriber banner, quota header and the active queue.
  Widget _settingsView(BuildContext context) {
    final active = _tasks.where((t) => !t.terminal).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        if ((_status?.entitled ?? true) && active.isEmpty && !_bannerDismissed)
          _newTaskBanner(context),
        _quotaHeader(context),
        if (_error != null && _tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(trP(context, 'op.loadFailed', [_error!]),
                style: TextStyle(fontSize: 12, color: ZColors.danger)),
          ),
        if (active.isNotEmpty)
          for (final t in active) ...[
            _taskCard(t),
            const SizedBox(height: 8),
          ]
        else ...[
          const SizedBox(height: 24),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(tr(context, 'op.empty'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ZInk.muted(context))),
            ),
          ),
        ],
      ],
    );
  }

  /// 历史 tab: 指令 / 时长 / 时间 rows, each deletable.
  Widget _historyView(BuildContext context) {
    final history = _tasks.where((t) => t.terminal).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        if (history.isNotEmpty)
          for (final t in history) ...[
            _taskCard(t, historyRow: true),
            const SizedBox(height: 8),
          ]
        else
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Text(tr(context, 'op.history.empty'),
                  style: TextStyle(color: ZInk.muted(context))),
            ),
          ),
      ],
    );
  }

  /// Subscriber banner above the queue until the first task exists
  /// (official newTask.bannerText).
  Widget _newTaskBanner(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr(context, 'op.banner'),
                    style: TextStyle(
                        fontSize: 11.5,
                        height: 1.5,
                        color: ZInk.soft(context))),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => setState(() => _bannerDismissed = true),
            ),
          ],
        ),
      ),
    );
  }

  /// 额度余量 + 最早可用 (page header per the official layout).
  Widget _quotaHeader(BuildContext context) {
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    if (!status.entitled) {
      final text = switch (status.reason) {
        OffPeakError.codingPlanOnly => tr(context, 'op.err.codingPlanOnly'),
        OffPeakError.quota => tr(context, 'op.err.quota'),
        _ => tr(context, 'op.err.unavailable'),
      };
      // 额度耗尽: official limitReachedAt line with the remaining wait.
      final remainingMs =
          status.reason == OffPeakError.quota
              ? status.quotaResetRemainingMs(
                  DateTime.now().millisecondsSinceEpoch)
              : null;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.lock_outline,
                      size: 18, color: ZColors.danger),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(text,
                        style: TextStyle(
                            fontSize: 13, color: ZInk.soft(context))),
                  ),
                ],
              ),
              if (remainingMs != null && remainingMs > 0) ...[
                const SizedBox(height: 6),
                Text(
                  trP(context, 'op.limitReachedAt',
                      [formatRemaining(context, remainingMs)]),
                  style: TextStyle(fontSize: 12, color: ZInk.muted(context)),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final parts = <String>[
      if (status.quotaRemainingMinutes != null)
        trP(context, 'op.quota',
            [formatMinutes(context, status.quotaRemainingMinutes!)]),
      if (status.earliestAvailableAt != null)
        trP(context, 'op.earliest',
            [relativeTime(context, status.earliestAvailableAt!)]),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.bolt_outlined, size: 18, color: ZColors.sky500),
            const SizedBox(width: 10),
            Expanded(
              child: Text(parts.join(' · '),
                  style:
                      TextStyle(fontSize: 13, color: ZInk.soft(context))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskCard(OffPeakTask task, {bool historyRow = false}) {
    final (statusLabel, statusColor) = _statusVisual(task);
    final canViewResult = task.completed && task.sessionId != null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          task.title.isEmpty ? task.prompt : task.title,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 暂停位置徽标 (official: #{position} 已暂停).
                      if (task.paused && task.queuePosition != null)
                        Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: ZColors.neutral500.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            trP(context, 'op.badge.paused',
                                ['${task.queuePosition}']),
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: ZColors.neutral500),
                          ),
                        ),
                      // 排队位置徽标 (official: 排队第 N 位).
                      if (task.queued && task.queuePosition != null)
                        Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: ZColors.sky500.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            trP(context, 'op.queue', ['${task.queuePosition}']),
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: ZColors.sky500),
                          ),
                        ),
                      Text(statusLabel,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: statusColor)),
                    ],
                  ),
                  if (task.prompt.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        task.prompt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: ZInk.muted(context)),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (task.createdAt != null)
                        relativeTime(context, task.createdAt!),
                      if (task.durationMs != null)
                        trP(context, 'op.duration', [
                          formatMinutes(context, task.durationMs! ~/ 60000)
                        ]),
                    ].join(' · '),
                    style:
                        TextStyle(fontSize: 11, color: ZInk.ghost(context)),
                  ),
                  if (task.failed && task.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        task.error!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            TextStyle(fontSize: 11, color: ZColors.danger),
                      ),
                    ),
                  if (canViewResult)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: FilledButton.tonalIcon(
                        onPressed: () => _openResult(task),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: Text(tr(context, 'op.viewResult')),
                        style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact),
                      ),
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => _menuAction(task, v),
              itemBuilder: (c) => [
                // Desktop supports editing queued/paused runs (offpeak-edit).
                if (!task.terminal)
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        const Icon(Icons.edit_outlined, size: 18),
                        const SizedBox(width: 8),
                        Text(tr(context, 'op.edit.menu')),
                      ],
                    ),
                  ),
                if (task.running || task.queued)
                  PopupMenuItem(
                    value: 'pause',
                    child: Row(
                      children: [
                        const Icon(Icons.pause_circle_outline, size: 18),
                        const SizedBox(width: 8),
                        Text(tr(context, 'tasks.pause')),
                      ],
                    ),
                  ),
                if (task.paused)
                  PopupMenuItem(
                    value: 'resume',
                    child: Row(
                      children: [
                        const Icon(Icons.play_circle_outline, size: 18),
                        const SizedBox(width: 8),
                        Text(tr(context, 'tasks.resume')),
                      ],
                    ),
                  ),
                if (!task.terminal)
                  PopupMenuItem(
                    value: 'cancel',
                    child: Row(
                      children: [
                        const Icon(Icons.stop_circle_outlined, size: 18),
                        const SizedBox(width: 8),
                        Text(tr(context, 'op.cancel')),
                      ],
                    ),
                  ),
                if (task.terminal)
                  PopupMenuItem(
                    value: historyRow ? 'history-delete' : 'delete',
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline, size: 18),
                        const SizedBox(width: 8),
                        Text(
                            tr(
                                context,
                                historyRow
                                    ? 'op.history.delete'
                                    : 'devices.menu.delete'),
                            style: TextStyle(
                                color: Theme.of(c).colorScheme.error)),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _menuAction(OffPeakTask task, String action) async {
    final session = _session;
    if (session == null) return;
    switch (action) {
      case 'edit':
        final s = _session;
        if (s == null || s.status != DeviceStatus.connected) return;
        await _showSheet(editing: task);
        return;
      case 'pause':
        // Official hint toasts accompany pause/continue.
        await _runOp(() async {
          await session.offPeak.pause(task.id);
          if (mounted) _toast(tr(context, 'op.pauseHint'));
        });
      case 'resume':
        await _runOp(() async {
          await session.offPeak.resume(task.id);
          if (mounted) _toast(tr(context, 'op.continueHint'));
        });
      case 'cancel':
        // Official confirm: 已修改的文件会保留.
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(tr(context, 'op.cancel.title')),
            content: Text(trP(context, 'op.cancel.body',
                [task.title.isEmpty ? task.prompt : task.title])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: Text(tr(context, 'devices.add.cancel'))),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(c).colorScheme.error,
                    foregroundColor: Theme.of(c).colorScheme.onError),
                onPressed: () => Navigator.pop(c, true),
                child: Text(tr(context, 'op.cancel.confirm')),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await _runOp(() => session.offPeak.cancel(task.id));
        }
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(tr(context, 'op.deleteTitle')),
            content: Text(tr(context, 'op.deleteBody')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: Text(tr(context, 'devices.add.cancel'))),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(c).colorScheme.error,
                    foregroundColor: Theme.of(c).colorScheme.onError),
                onPressed: () => Navigator.pop(c, true),
                child: Text(tr(context, 'op.delete.confirm')),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await _runOp(() => session.offPeak.remove(task.id));
        }
      case 'history-delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(tr(context, 'op.deleteTitle')),
            content: Text(tr(context, 'op.deleteBody')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: Text(tr(context, 'devices.add.cancel'))),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(c).colorScheme.error,
                    foregroundColor: Theme.of(c).colorScheme.onError),
                onPressed: () => Navigator.pop(c, true),
                child: Text(tr(context, 'op.history.delete')),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await _runOp(() => session.offPeak.deleteHistory(task.id));
        }
    }
    await _load();
  }

  (String, Color) _statusVisual(OffPeakTask task) => switch (task.status) {
        'queued' => (tr(context, 'op.status.queued'), ZColors.sky500),
        'running' => (tr(context, 'op.status.running'), ZColors.success),
        'paused' => (tr(context, 'op.status.paused'), ZColors.neutral500),
        'completed' => (tr(context, 'op.status.completed'), ZColors.success),
        'failed' => (tr(context, 'op.status.failed'), ZColors.danger),
        'cancelled' => (tr(context, 'op.status.cancelled'), ZColors.neutral500),
        _ => (task.status, ZColors.neutral400),
      };

  Widget _centerNote(BuildContext context, String title, String body) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 44, color: ZInk.ghost(context)),
            const SizedBox(height: 16),
            Text(title,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: ZInk.solid(context))),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: ZInk.faint(context))),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => widget.hub.ensure(widget.device),
              child: Text(tr(context, 'tasks.retry')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Create/Edit form (bottom sheet): 标题 → 指令 → 模型 → 思考等级 →
/// 时间选项 → 权限模式, plus quick templates that prefill title + prompt.
///
/// [editing] turns the sheet into the desktop's offpeak-edit mode: fields
/// prefill from the task and submit routes through OffPeakPort.update.
///
/// 保持唤醒 (keepAwake) is a local preference: it keeps the native
/// connection alive so results (and later notifications) arrive — it is
/// not part of the off-peak-run wire schema.
class OffPeakSheet extends StatefulWidget {
  final OffPeakHost session;

  /// Non-null: edit this existing run instead of creating a new one.
  final OffPeakTask? editing;

  /// prepareWorkspace loader (the full device session): fallback source for
  /// the model selector options.
  final Future<WorkspacePrep> Function()? loadOptions;

  /// Desktop off-peak availability payload's `allowedModels`: the official
  /// option source for the model selector (plain model names, first is the
  /// default — no unspecified choice, matching the desktop form).
  final List<String>? allowedModels;

  /// Desktop `allowedModelConfigs` entries: `{model?, reasoning:
  /// {levels, defaultLevel}}` — drives the thought-level selector.
  final List<Map<String, dynamic>> allowedModelConfigs;

  /// Official model-selection choices (`model-selection` getView). When
  /// non-empty these back the model picker (composite `provider/model`
  /// values) and the submission carries the structured `modelSelection`.
  final List<OffPeakModelChoice> modelChoices;

  const OffPeakSheet({
    super.key,
    required this.session,
    this.editing,
    this.loadOptions,
    this.allowedModels,
    this.allowedModelConfigs = const [],
    this.modelChoices = const [],
  });

  @override
  State<OffPeakSheet> createState() => _OffPeakSheetState();
}

class _OffPeakSheetState extends State<OffPeakSheet> {
  late final TextEditingController _title;
  late final TextEditingController _prompt;

  /// Structured selection (modelChoices path); composite `provider/model`.
  OffPeakModelChoice? _choice;

  /// Legacy plain-model selection (allowedModels/prepareWorkspace path).
  String? _model;
  String? _thought;
  DateTime? _earliest;
  bool _keepAwake = true;
  String _permission = 'build';
  bool _submitting = false;

  /// A task's stored model kept selectable when absent from today's list.
  String? _modelExtraValue;

  /// Snapshot of the pristine form (discard confirmation compares here).
  late final Map<String, Object?> _pristine;
  bool get _dirty =>
      _pristine['title'] != _title.text.trim() ||
      _pristine['prompt'] != _prompt.text.trim() ||
      _pristine['model'] != _effectiveModelValue ||
      _pristine['thought'] != _thought ||
      _pristine['earliest'] != null ||
      _pristine['permission'] != _permission;

  /// The official one-time hint toast fires on the first non-full-access
  /// submit (desktop behavior).
  bool _fullAccessHintShown = false;

  static const _templateKeys = ['tpl.ci', 'tpl.docs', 'tpl.standup'];

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _title = TextEditingController(text: e?.title ?? '');
    _prompt = TextEditingController(text: e?.prompt ?? '');
    // Structured restore wins (desktop modelSelection contract); legacy
    // plain model strings stay on the old path.
    final stored = e?.modelSelection;
    if (stored != null) {
      _choice = _choiceFor(stored.providerId, stored.modelId) ??
          OffPeakModelChoice(
            providerId: stored.providerId,
            modelId: stored.modelId,
            name: stored.modelId,
            reasoningLevels: stored.reasoningLevel == null
                ? const []
                : [stored.reasoningLevel!],
          );
      if (stored.reasoningLevel != null) _thought = stored.reasoningLevel;
    } else {
      _model = (e?.model == null || (e?.model ?? '').isEmpty) ? null : e!.model;
      if (_model != null &&
          widget.allowedModels != null &&
          !widget.allowedModels!.contains(_model)) {
        // Keep showing a stored model that left today's allowlist.
        _modelExtraValue = _model;
      }
      if (widget.modelChoices.isNotEmpty && _model != null) {
        // A legacy `provider/model` composite can still map onto the view.
        final slash = _model!.indexOf('/');
        if (slash > 0) {
          _choice = _choiceFor(
            _model!.substring(0, slash),
            _model!.substring(slash + 1),
          );
          if (_choice != null) _modelExtraValue = null;
        }
      }
    }
    _thought ??= e?.raw['thoughtLevel'] as String?;
    _permission = e?.permissionMode ?? 'build';
    _pristine = {
      'title': _title.text.trim(),
      'prompt': _prompt.text.trim(),
      'model': _effectiveModelValue,
      'thought': _thought,
      'earliest': null,
      'permission': _permission,
    };
  }

  /// Choice for a provider/model pair in today's view; null when absent.
  OffPeakModelChoice? _choiceFor(String providerId, String modelId) {
    for (final c in widget.modelChoices) {
      if (c.providerId == providerId && c.modelId == modelId) return c;
    }
    return null;
  }

  /// The picker's current value: structured composite, else the legacy
  /// plain model (kept selectable via _modelExtraValue).
  String? get _effectiveModelValue =>
      _choice?.composite ?? (_model ?? _modelExtraValue);

  /// Effective structured selection for the wire: the picked choice, or —
  /// for a fresh form the user left untouched — the first available choice
  /// (desktop picks allowedModels[0]).
  OffPeakModelChoice? get _effectiveChoice {
    if (_choice != null) return _choice;
    if (widget.editing == null &&
        _model == null &&
        widget.modelChoices.isNotEmpty) {
      return widget.modelChoices.first;
    }
    return null;
  }

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    super.dispose();
  }

  /// Effective selection sent on the wire.
  String? get _effectiveModel => _model ?? _modelExtraValue;

  /// Thought levels for the selected model: the model-selection view's
  /// reasoning levels first (official resolveModelThoughtOption source),
  /// then allowedModelConfig's reasoning block.
  List<String> get _thoughtLevels {
    final choice = _effectiveChoice;
    if (choice != null && choice.reasoningLevels.isNotEmpty) {
      return choice.reasoningLevels;
    }
    final configs = widget.allowedModelConfigs;
    if (configs.isEmpty) return const [];
    var scope = const <Map<String, dynamic>>[];
    final model = _effectiveModel;
    if (model != null && model.isNotEmpty) {
      scope = [
        for (final c in configs)
          if ('${c['model'] ?? ''}' == model ||
              '${c['model'] ?? ''}' == choice?.composite)
            c.cast<String, dynamic>(),
      ];
    }
    if (scope.isEmpty && configs.length == 1) scope = configs;
    for (final c in scope) {
      final reasoning = c['reasoning'];
      if (reasoning is! Map) continue;
      final levels = reasoning['levels'];
      if (levels is! List || levels.isEmpty) continue;
      return [for (final l in levels) '$l'];
    }
    return const [];
  }

  Future<void> _pickEarliest() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _earliest ?? DateTime.now().add(const Duration(hours: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
          _earliest ?? DateTime.now().add(const Duration(hours: 1))),
    );
    if (time == null || !mounted) return;
    setState(() {
      _earliest =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  /// Official discard confirmation shown over dirty sheets.
  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'op.discard.title')),
        content: Text(tr(context, 'op.discard.body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(c).colorScheme.error,
                foregroundColor: Theme.of(c).colorScheme.onError),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr(context, 'op.discard.confirm')),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (_prompt.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'op.err.prompt'))));
      return;
    }
    setState(() => _submitting = true);
    try {
      final choice = _effectiveChoice;
      final legacyModel = choice?.composite ?? _effectiveModel;
      final e = widget.editing;
      if (e != null) {
        await widget.session.offPeak.update(
          e.id,
          OffPeakUpdateInput(
            title: _title.text,
            prompt: _prompt.text,
            permissionMode: _permission,
            model: legacyModel,
            thoughtLevel: _thought,
            modelSelection: choice?.selection(reasoningLevel: _thought),
          ),
        );
        if (!mounted) return;
        Navigator.pop(context);
        return;
      }
      final scope = widget.session.offPeakScope;
      final workspacePath = '${scope['workspacePath'] ?? ''}';
      if (workspacePath.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'op.err.noWorkspace'))));
        return;
      }
      if (_permission != 'yolo' && !_fullAccessHintShown) {
        _fullAccessHintShown = true;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'op.fullAccessHint'))));
      }
      await widget.session.offPeak.submit(OffPeakSubmitInput(
        prompt: _prompt.text,
        workspacePath: workspacePath,
        workspaceIdentity: scope['workspaceIdentity'] as String?,
        permissionMode: _permission,
        model: legacyModel,
        thoughtLevel: _thought,
        modelSelection: choice?.selection(reasoningLevel: _thought),
        earliestAtMs: _earliest?.millisecondsSinceEpoch,
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'op.created'))));
      Navigator.pop(context);
    } on OffPeakError catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_errorText(context, err))));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trP(context, 'op.err.other', ['$err']))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _errorText(BuildContext context, OffPeakError e) => switch (e.kind) {
        OffPeakError.codingPlanOnly => tr(context, 'op.err.codingPlanOnly'),
        OffPeakError.quota => tr(context, 'op.err.quota'),
        OffPeakError.unavailable => tr(context, 'op.err.unavailable'),
        _ => trP(context, 'op.err.other', [e.message]),
      };

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing != null;
    final thoughts = _thoughtLevels;
    return PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _submitting) return;
        final ok = await _confirmDiscard();
        if (ok && mounted) Navigator.pop(this.context);
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(editing ? tr(context, 'op.edit') : tr(context, 'op.add'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                  editing
                      ? tr(context, 'op.edit.hint')
                      : tr(context, 'op.hint'),
                  style: TextStyle(fontSize: 11, color: ZInk.muted(context))),
              const SizedBox(height: 12),
              if (!editing)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final key in _templateKeys)
                      ActionChip(
                        label: Text(tr(context, 'op.$key.title'),
                            style: const TextStyle(fontSize: 12)),
                        onPressed: () => setState(() {
                          _title.text = tr(context, 'op.$key.title');
                          _prompt.text = tr(context, 'op.$key.prompt');
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                decoration: InputDecoration(
                    labelText: tr(context, 'op.name'),
                    hintText: tr(context, 'op.name.hint')),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _prompt,
                maxLines: 3,
                decoration: InputDecoration(
                    labelText: tr(context, 'op.prompt'),
                    hintText: tr(context, 'op.prompt.hint')),
              ),
              const SizedBox(height: 10),
              ModelOptionField(
                loadOptions: widget.loadOptions,
                // Rich options from the official model-selection view win;
                // null direct lists keep the prepareWorkspace fallback alive
                // when neither the view nor an allowlist arrived.
                directOptions: widget.modelChoices.isEmpty
                    ? null
                    : [
                        for (final c in widget.modelChoices)
                          (
                            value: c.composite,
                            name: c.name,
                            subtitle: c.providerName,
                          ),
                      ],
                directValues: (widget.modelChoices.isNotEmpty ||
                        (widget.allowedModels == null &&
                            _modelExtraValue == null))
                    ? null
                    : [
                        ...?widget.allowedModels,
                        if (_modelExtraValue != null &&
                            !(widget.allowedModels ?? const [])
                                .contains(_modelExtraValue))
                          _modelExtraValue!,
                      ],
                optionId: 'model',
                labelText: tr(context, 'op.model'),
                // Desktop off-peak form: no unspecified choice — first
                // allowed model is the default.
                noneLabel: null,
                defaultToFirst:
                    !editing && _modelExtraValue == null && _choice == null,
                value: _effectiveModelValue,
                onChanged: (v) => setState(() {
                  if (v != null) {
                    final slash = v.indexOf('/');
                    if (slash > 0) {
                      _choice = _choiceFor(
                        v.substring(0, slash),
                        v.substring(slash + 1),
                      );
                    }
                  } else {
                    _choice = null;
                  }
                  _model = v;
                  _modelExtraValue = null;
                  if (!thoughts.contains(_thought)) _thought = null;
                }),
              ),
              const SizedBox(height: 10),
              ModelOptionField(
                loadOptions: thoughts.isEmpty ? widget.loadOptions : null,
                directValues: thoughts.isEmpty ? null : thoughts,
                optionId: 'thought_level',
                labelText: tr(context, 'op.thought'),
                noneLabel: tr(context, 'op.thought.default'),
                value: _thought,
                onChanged: (v) => setState(() => _thought = v),
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: _pickEarliest,
                borderRadius: BorderRadius.circular(8),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: tr(context, 'op.earliestAt'),
                    suffixIcon: const Icon(Icons.event_outlined, size: 18),
                  ),
                  child: Text(
                    _earliest == null
                        ? tr(context, 'op.earliest.any')
                        : _fmt(_earliest!),
                    style: TextStyle(
                        fontSize: 13,
                        color: _earliest == null
                            ? ZInk.ghost(context)
                            : ZInk.soft(context)),
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(tr(context, 'op.keepAwake'),
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text(tr(context, 'op.keepAwakeHint'),
                    style:
                        TextStyle(fontSize: 11, color: ZInk.faint(context))),
                value: _keepAwake,
                onChanged: (v) => setState(() => _keepAwake = v),
              ),
              DropdownButtonFormField<String>(
                initialValue: _permission,
                decoration:
                    InputDecoration(labelText: tr(context, 'op.permission')),
                items: [
                  for (final m in const ['build', 'plan', 'yolo'])
                    DropdownMenuItem(
                        value: m,
                        child: Text(tr(context, 'op.permission.$m'))),
                ],
                onChanged: (v) =>
                    setState(() => _permission = v ?? _permission),
              ),
              const SizedBox(height: 6),
              Text(
                tr(context, 'op.permissionWarning'),
                style: TextStyle(
                    fontSize: 11, height: 1.5, color: ZInk.faint(context)),
              ),
              if (editing) ...[
                const SizedBox(height: 6),
                // 峰时警示 — official edit-mode notice.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_outlined,
                        size: 14, color: ZColors.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(tr(context, 'op.peakWarning'),
                          style: TextStyle(
                              fontSize: 11,
                              height: 1.5,
                              color: ZInk.faint(context))),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(editing
                          ? tr(context, 'op.edit.save')
                          : tr(context, 'op.submit')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(DateTime t) =>
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// 额度重置剩余等待: ms → 「2 小时 30 分钟后」/「40 分钟后」.
String formatRemaining(BuildContext context, int ms) {
  if (ms < 60 * 60000) {
    return trP(context, 'op.remaining.min',
        ['${(ms / 60000).clamp(1, 59).round()}']);
  }
  final hours = ms ~/ 3600000;
  final minutes = ((ms % 3600000) / 60000).round();
  return minutes == 0
      ? trP(context, 'op.hours', ['$hours'])
      : trP(context, 'op.remaining.hoursMin', ['$hours', '$minutes']);
}

/// 90 → 90 分钟; 5400 → 1.5 小时.
String formatMinutes(BuildContext context, int minutes) {
  if (minutes < 60) return trP(context, 'op.minutes', ['$minutes']);
  return trP(context, 'op.hours', [(minutes / 60).toStringAsFixed(1)]);
}
