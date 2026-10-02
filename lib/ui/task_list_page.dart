// ignore_for_file: deprecated_member_use // ohos fork's Flutter predates RadioGroup; drop when it lands
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/conversation.dart';
import '../state/device_session.dart';
import '../state/device_store.dart';
import 'automations_page.dart';
import 'chat/chat_page.dart';
import 'desktop_settings_page.dart';
import 'device_usage_page.dart';
import 'model_providers_page.dart';
import 'off_peak_page.dart';
import 'phase_pill.dart';
import 'remote_page.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Native task list of one device (official mobile layout): a connection
/// banner, the "workspaces and tasks" header with stats, and one card per
/// workspace whose rows are the live sessions. Tapping a task opens the
/// NATIVE chat page (no WebView suspend); the WebView stays available from
/// the overflow menu as a fallback.
class TaskListPage extends StatefulWidget {
  final DeviceStore store;
  final DeviceSessionHub hub;
  final Device device;
  final ThemeController? theme;

  /// Test seam: overrides `hub.sessionOf(device.id)` when set.
  @visibleForTesting
  final DeviceSession? sessionOverride;

  /// Test / screenshot seam: pre-select a task in the desktop right pane.
  @visibleForTesting
  final String? initialPaneSessionId;
  @visibleForTesting
  final String? initialPaneTitle;

  const TaskListPage({
    super.key,
    required this.store,
    required this.hub,
    required this.device,
    this.theme,
    this.sessionOverride,
    this.initialPaneSessionId,
    this.initialPaneTitle,
  });

  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends State<TaskListPage> {
  /// Per-workspace expand overrides, both directions (official web model):
  /// absent = default target state — only the ACTIVE workspace (the one
  /// owning the device's live session) is expanded; every other card starts
  /// collapsed. Overrides survive until 收起全部 clears them.
  final Map<String, bool> _expandOverrides = {};

  /// Official 整理任务 state: grouping (workspace cards / timeline buckets)
  /// and ordering (updated = lastActivityAt, created = createdAt).
  String _groupBy = 'workspace';
  String _sortBy = 'updated';

  /// Desktop sidebar 归档 filter: shows only archived task rows (the web
  /// sidebar carries the same entry; empty when nothing is archived).
  bool _showArchived = false;

  /// Organize preferences persist across restarts (web parity: the mobile
  /// home stores them in localStorage
  /// `zcode-web-remote-control-mobile-task-home-preferences`, same default).
  static const _organizePrefsKey = 'zlinker_task_organize_v1';

  @override
  void initState() {
    super.initState();
    _paneSessionId = widget.initialPaneSessionId;
    _paneTitle = widget.initialPaneTitle;
    _loadOrganizePrefs();
  }

  Future<void> _loadOrganizePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_organizePrefsKey);
    if (raw == null || !mounted) return;
    try {
      final saved = jsonDecode(raw);
      if (saved is! Map) return;
      setState(() {
        if (saved['groupBy'] == 'workspace' || saved['groupBy'] == 'timeline') {
          _groupBy = saved['groupBy'];
        }
        if (saved['sortBy'] == 'created' || saved['sortBy'] == 'updated') {
          _sortBy = saved['sortBy'];
        }
      });
    } catch (_) {}
  }

  Future<void> _saveOrganizePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _organizePrefsKey,
      jsonEncode({'groupBy': _groupBy, 'sortBy': _sortBy}),
    );
  }

  /// Dual-pane desktop selection (≥768px): the task opened in the right
  /// pane instead of a pushed route.
  String? _paneSessionId;
  String? _paneTitle;
  String? _paneInitialComposerText;
  bool _panePinned = false;

  /// Official breakpoint: Tailwind md — single column below, dual ≥768.
  static const double kDualPaneBreakpoint = 768;

  /// Official sidebar width (`--workspace-sidebar-panel-width`).
  static const double kSidebarWidth = 264;

  DeviceSession? get _session =>
      widget.sessionOverride ?? widget.hub.sessionOf(widget.device.id);

  bool _isWorkspaceActive(DeviceSession session, Map<String, dynamic> ws) =>
      identical(session.activeWorkspace, ws) ||
      workspaceKeyOf(ws) == workspaceKeyOf(session.activeWorkspace ?? const {});

  /// Shared expand state for the mobile card and the desktop sidebar folder:
  /// manual override wins, otherwise the active workspace is expanded.
  bool _isWorkspaceExpanded(String key, {required bool isActive}) =>
      _expandOverrides[key] ?? isActive;

  /// Shared header tap: two-way toggle (official web aria-expanded flips both
  /// ways). The mobile home EXPANDS ONLY (web parity: switching workspaces
  /// happens when opening a task — workspace-bridge-open rides the taskId);
  /// the desktop sidebar still switches on tap ([openIfInactive]).
  void _toggleWorkspace(
    DeviceSession session,
    Map<String, dynamic> ws, {
    bool openIfInactive = true,
  }) {
    final isActive = _isWorkspaceActive(session, ws);
    final key = workspaceKeyOf(ws) ?? workspaceTitle(ws);
    if (!isActive && openIfInactive) session.openWorkspace(ws);
    setState(
      () => _expandOverrides[key] = !_isWorkspaceExpanded(
        key,
        isActive: isActive,
      ),
    );
  }

  /// 收起全部工作区: one-way collapse of every workspace (official web keeps
  /// the label and icon constant; tapping it again just re-collapses).
  void _collapseAllWorkspaces(DeviceSession? session) {
    final workspaces = session?.workspaces ?? const <Map<String, dynamic>>[];
    setState(() {
      for (final ws in workspaces) {
        _expandOverrides[workspaceKeyOf(ws) ?? workspaceTitle(ws)] = false;
      }
    });
  }

  /// Official 整理任务 ordering: 更新时间 = lastActivityAt (device default),
  /// 创建时间 = createdAt.
  List<SessionEntry> _sortedEntries(List<SessionEntry> entries) {
    if (_sortBy != 'created') return entries;
    return [...entries]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  // ------------------------------------------------- merged task data source
  //
  // The relay overview (bootstrap / workspace-list-updated) carries every
  // workspace's tasks (`Dg`: displayStatus/pinned/archived/unreadAt) — the
  // web mobile home renders non-active workspaces and the archive view from
  // it. The active workspace additionally has the live sessions-index with
  // richer phase + pendingInteraction, which wins per task id.

  /// Workspace key of a relay task (`Dg.workspaceIdentity ?? workspacePath`,
  /// same rule as [workspaceKeyOf]).
  String? _relayTaskKey(Map<String, dynamic> task) {
    final identity = task['workspaceIdentity'];
    if (identity is String && identity.trim().isNotEmpty) {
      return identity.trim();
    }
    final path = task['workspacePath'];
    if (path is String && path.isNotEmpty) return path;
    return null;
  }

  Map<String, dynamic>? _workspaceForKey(DeviceSession session, String? key) {
    if (key == null) return null;
    for (final ws in session.workspaces) {
      if (workspaceKeyOf(ws) == key) return ws;
    }
    return null;
  }

  /// Relay tasks of one workspace as row entries (non-archived unless
  /// [archivedOnly]).
  List<SessionEntry> _relayEntriesFor(
    DeviceSession session,
    Map<String, dynamic> ws, {
    bool archivedOnly = false,
  }) {
    final key = workspaceKeyOf(ws);
    if (key == null) return const [];
    return [
      for (final t in session.relayTasks)
        if (_relayTaskKey(t) == key && (t['archived'] == true) == archivedOnly)
          SessionEntry.fromRelayTask(t),
    ];
  }

  /// Every non-archived task of the device as `(entry, workspace)` pairs —
  /// relay tasks first, live sessions-index entries overriding per id.
  List<(SessionEntry, Map<String, dynamic>?)> _allTaskEntries(
    DeviceSession session,
  ) {
    final byId = <String, (SessionEntry, Map<String, dynamic>?)>{};
    for (final t in session.relayTasks) {
      if (t['archived'] == true) continue;
      final entry = SessionEntry.fromRelayTask(t);
      byId[entry.sessionId] = (
        entry,
        _workspaceForKey(session, _relayTaskKey(t)),
      );
    }
    final active = session.activeWorkspace;
    if (session.sessions?.ready == true) {
      for (final e in session.sessions!.list) {
        if (e.raw['archived'] == true) continue;
        byId[e.sessionId] = (e, active);
      }
    }
    return byId.values.toList();
  }

  /// Pinned tasks across the device: live entries win, relay tasks fill in
  /// the workspaces the native link hasn't opened.
  List<SessionEntry> _pinnedEntries(DeviceSession session) {
    final byId = <String, SessionEntry>{};
    for (final t in session.relayTasks) {
      if (t['pinned'] != true || t['archived'] == true) continue;
      final e = SessionEntry.fromRelayTask(t);
      byId[e.sessionId] = e;
    }
    if (session.sessions?.ready == true) {
      for (final e in session.sessions!.list) {
        if (e.raw['pinned'] == true) byId[e.sessionId] = e;
      }
    }
    final list = byId.values.toList()
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return list;
  }

  /// Task count for the official summary line: all non-archived tasks on
  /// the device (falls back to the active workspace's live list).
  int _totalTaskCount(DeviceSession session) {
    final relay = session.relayTasks.where((t) => t['archived'] != true).length;
    if (relay > 0) return relay;
    return session.sessions?.list
            .where((e) => e.raw['archived'] != true)
            .length ??
        0;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= kDualPaneBreakpoint) {
          return _buildDualPane(context);
        }
        return _buildMobile(context);
      },
    );
  }

  Widget _buildMobile(BuildContext context) {
    final session = _session;
    final online =
        session != null &&
        session.status == DeviceStatus.connected &&
        !session.kicked &&
        (session.error?.isEmpty ?? true);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(context, 'tasks.banner.onlineTitle'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                online
                    ? tr(context, 'tasks.banner.onlineSubtitle')
                    : widget.device.label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: online ? ZColors.pillSuccessBg : ZInk.faint(context),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (widget.theme != null)
            IconButton(
              tooltip: tr(context, 'settings.theme'),
              icon: Icon(switch (widget.theme!.mode) {
                ThemeMode.dark => Icons.palette_outlined,
                ThemeMode.light => Icons.palette_outlined,
                _ => Icons.palette_outlined,
              }, size: 20),
              onPressed: widget.theme!.cycle,
            ),
          _overflowMenu(),
        ],
      ),
      body: _listBody(context),
    );
  }

  /// Official desktop layout (≥768): IDE-style sidebar (新建/搜索/项目树)
  /// + 1px divider + rounded chat pane — not a shrunk mobile card list.
  Widget _buildDualPane(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark
          ? ZColors.darkBackground
          : ZColors.lightBackground,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: kSidebarWidth,
            child: ColoredBox(
              color: isDark ? ZColors.darkSidebar : ZColors.lightSidebar,
              child: _desktopSidebar(context),
            ),
          ),
          Container(width: 1, color: const Color(0xFF333333)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: isDark
                      ? ZColors.darkBackground
                      : ZColors.lightBackground,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: ZInk.hairline(context)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 320),
                    child: _chatPane(context),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Official IDE sidebar: nav actions → projects tree → device footer.
  Widget _desktopSidebar(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.hub,
      builder: (context, _) {
        final session = _session;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: const Icon(Icons.arrow_back, size: 18),
                    color: ZInk.muted(context),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      widget.device.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: ZInk.solid(context),
                      ),
                    ),
                  ),
                  _overflowMenu(),
                ],
              ),
            ),
            _sidebarNavItem(
              context,
              icon: Icons.add,
              label: tr(context, 'tasks.sidebar.new'),
              shortcut: 'Ctrl+N',
              onTap: () => _openChat(title: tr(context, 'tasks.new')),
            ),
            _sidebarNavItem(
              context,
              icon: Icons.search,
              label: tr(context, 'tasks.search'),
              shortcut: 'Ctrl+K',
              onTap: () => _openCommandSearch(),
            ),
            _sidebarNavItem(
              context,
              icon: Icons.extension_outlined,
              label: tr(context, 'tasks.sidebar.plugins'),
              shortcut: '',
              onTap: () => _openPluginMarketplaceHint(),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr(context, 'tasks.projects'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: ZInk.faint(context),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr(context, 'tasks.collapseAll'),
                    icon: const Icon(Icons.keyboard_double_arrow_up, size: 16),
                    color: ZInk.muted(context),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _collapseAllWorkspaces(_session),
                  ),
                  IconButton(
                    tooltip: tr(context, 'tasks.sidebar.filterSort'),
                    icon: const Icon(Icons.filter_list, size: 16),
                    color: ZInk.muted(context),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showTidyPanel(context),
                  ),
                  IconButton(
                    tooltip: tr(context, 'tasks.sidebar.archive'),
                    icon: Icon(
                      _showArchived
                          ? Icons.inventory_2_outlined
                          : Icons.inventory_outlined,
                      size: 16,
                    ),
                    color: _showArchived ? ZColors.sky500 : ZInk.muted(context),
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => _showArchived = !_showArchived),
                  ),
                ],
              ),
            ),
            Expanded(
              child: session == null || session.workspaces.isEmpty
                  ? _fallback(context, session)
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(6, 0, 6, 16),
                      children: [
                        ..._desktopPinned(context, session),
                        for (final ws in session.workspaces)
                          _desktopWorkspaceFolder(context, session, ws),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _sidebarNavItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String shortcut,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: ZInk.muted(context)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 13.5, color: ZInk.soft(context)),
              ),
            ),
            Text(
              shortcut,
              style: TextStyle(fontSize: 11, color: ZInk.ghost(context)),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _desktopPinned(BuildContext context, DeviceSession session) {
    final entries = _pinnedEntries(session);
    if (entries.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Text(
          tr(context, 'tasks.pinned'),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: ZInk.ghost(context),
          ),
        ),
      ),
      for (final e in entries)
        _desktopTaskRow(
          context,
          session,
          e,
          selected: e.sessionId == _paneSessionId,
          workspace: _workspaceForKey(
            session,
            e.raw['workspaceIdentity'] as String? ??
                e.raw['workspacePath'] as String?,
          ),
        ),
    ];
  }

  Widget _desktopWorkspaceFolder(
    BuildContext context,
    DeviceSession session,
    Map<String, dynamic> ws,
  ) {
    final isActive = _isWorkspaceActive(session, ws);
    final key = workspaceKeyOf(ws) ?? workspaceTitle(ws);
    final expanded = _isWorkspaceExpanded(key, isActive: isActive);
    final sessions = isActive ? session.sessions : null;
    // Live index for the active workspace; relay tasks for the rest.
    final allEntries = sessions?.ready == true
        ? sessions!.list
        : _relayEntriesFor(session, ws);
    final entries = _showArchived
        ? [
            for (final e in allEntries)
              if (e.raw['archived'] == true) e,
          ]
        : [
            for (final e in allEntries)
              if (e.raw['archived'] != true) e,
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _toggleWorkspace(session, ws),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 16,
                  color: ZInk.ghost(context),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.folder_outlined,
                  size: 15,
                  color: ZInk.muted(context),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    workspaceTitle(ws),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: ZInk.soft(context),
                    ),
                  ),
                ),
                if (isActive || entries.isNotEmpty)
                  Text(
                    '${entries.length}',
                    style: TextStyle(fontSize: 11, color: ZInk.ghost(context)),
                  ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          for (final e in entries)
            _desktopTaskRow(
              context,
              session,
              e,
              selected: e.sessionId == _paneSessionId,
              indent: true,
              workspace: isActive ? null : ws,
            ),
          if (_showArchived && entries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 2, 8, 6),
              child: Text(
                tr(context, 'tasks.archive.empty'),
                style: TextStyle(fontSize: 12, color: ZInk.ghost(context)),
              ),
            ),
        ],
      ],
    );
  }

  Widget _desktopTaskRow(
    BuildContext context,
    DeviceSession session,
    SessionEntry entry, {
    bool selected = false,
    bool indent = false,
    Map<String, dynamic>? workspace,
  }) {
    final title = entry.title.trim().isEmpty
        ? tr(context, 'tasks.untitled')
        : entry.title;
    return Padding(
      padding: EdgeInsets.only(left: indent ? 12 : 0),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _openWorkspaceTask(session, workspace, entry, title),
          onLongPress: () {
            final s = _session;
            if (s != null) _taskActions(context, s, entry);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                      color: ZInk.solid(context),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  relativeTimeShort(context, entry.lastActivityAt),
                  style: TextStyle(fontSize: 11, color: ZInk.ghost(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Right pane: the selected task's chat, or the empty placeholder.
  Widget _chatPane(BuildContext context) {
    final session = _session;
    final id = _paneSessionId;
    final title = _paneTitle;
    if (session == null || title == null) {
      return Center(
        child: Text(
          tr(context, 'tasks.paneHint'),
          style: TextStyle(fontSize: 13, color: ZInk.faint(context)),
        ),
      );
    }
    return ChatPage(
      key: ValueKey('${id ?? 'draft'}-${_paneInitialComposerText ?? ''}'),
      gateway: session,
      sessionId: id,
      title: title,
      theme: widget.theme,
      embedded: true,
      initialComposerText: _paneInitialComposerText,
      initialPinned: _panePinned,
      workspaceLabel: session.activeWorkspace != null
          ? workspaceTitle(session.activeWorkspace!)
          : null,
    );
  }

  Future<void> _openCommandSearch() async {
    final session = _session;
    if (session == null || session.status != DeviceStatus.connected) return;
    WorkspacePrep? prep;
    try {
      prep = await session.prepareWorkspace();
    } catch (_) {}
    if (!mounted) return;
    final commands = prep?.slashCommands ?? const <SlashCommand>[];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) {
        final query = ValueNotifier('');
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(sheetCtx).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: tr(sheetCtx, 'tasks.commandSearch'),
                      prefixIcon: const Icon(Icons.search, size: 20),
                    ),
                    onChanged: (v) => query.value = v,
                  ),
                ),
                Flexible(
                  child: ValueListenableBuilder<String>(
                    valueListenable: query,
                    builder: (context, q, _) {
                      final needle = q.trim().toLowerCase();
                      final filtered = commands.where((c) {
                        if (needle.isEmpty) return true;
                        return c.name.toLowerCase().contains(needle) ||
                            c.description.toLowerCase().contains(needle);
                      }).toList();
                      if (filtered.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            tr(sheetCtx, 'tasks.commandSearch.empty'),
                            style: TextStyle(
                              fontSize: 13,
                              color: ZInk.faint(sheetCtx),
                            ),
                          ),
                        );
                      }
                      return ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final c = filtered[i];
                          final label = c.name.startsWith('/')
                              ? c.name
                              : '/${c.name}';
                          return ListTile(
                            title: Text(label),
                            subtitle: c.description.isNotEmpty
                                ? Text(
                                    c.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : null,
                            onTap: () {
                              Navigator.of(sheetCtx).pop();
                              _openChat(
                                title: tr(this.context, 'tasks.new'),
                                initialComposerText: label,
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _overflowMenu() {
    return PopupMenuButton<String>(
      onSelected: _onMenu,
      itemBuilder: (c) => [
        PopupMenuItem(
          value: 'automations',
          child: Row(
            children: [
              const Icon(Icons.schedule_outlined, size: 18),
              const SizedBox(width: 8),
              Text(tr(context, 'tasks.menu.automations')),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'offPeak',
          child: Row(
            children: [
              const Icon(Icons.nights_stay_outlined, size: 18),
              const SizedBox(width: 8),
              Text(tr(context, 'tasks.menu.offPeak')),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'usage',
          child: Text(tr(context, 'tasks.menu.usage')),
        ),
        PopupMenuItem(
          value: 'providers',
          child: Text(tr(context, 'tasks.menu.providers')),
        ),
        PopupMenuItem(
          value: 'archive',
          child: Row(
            children: [
              Icon(
                _showArchived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              const SizedBox(width: 8),
              Text(
                tr(
                  context,
                  _showArchived
                      ? 'tasks.action.unarchiveView'
                      : 'tasks.action.archiveView',
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'web',
          child: Row(
            children: [
              const Icon(Icons.open_in_browser, size: 18),
              const SizedBox(width: 8),
              Text(tr(context, 'tasks.openWeb')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _listBody(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.hub,
      builder: (context, _) {
        final session = _session;
        final banner = _ConnectionBanner(session: session, onWeb: _openRemote);
        // Lazy rows (official list virtualizes): widgets are cheap config
        // objects, ListView.builder only inflates what's near the viewport,
        // so collapse toggles never rebuild the whole list's elements.
        final rows = <Widget>[
          banner,
          const SizedBox(height: 12),
          _headerRow(context, session),
          const SizedBox(height: 12),
          if (session != null && _showArchived)
            ..._archiveView(context, session)
          else ...[
            if (session != null) ..._pinnedGroup(context, session),
            if (session == null || session.workspaces.isEmpty)
              _fallback(context, session)
            else if (_groupBy == 'timeline')
              ..._timelineGroups(context, session)
            else
              for (final ws in session.workspaces)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _workspaceCard(context, session, ws),
                ),
          ],
        ];
        return RefreshIndicator(
          onRefresh: () async =>
              session?.reloadTasks() ?? widget.hub.ensure(widget.device),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
            itemCount: rows.length,
            itemBuilder: (context, i) => rows[i],
          ),
        );
      },
    );
  }

  /// 插件市场: the marketplace is managed by the desktop app (the remote
  /// web button has no embedded view either) — surface that honestly.
  Future<void> _openPluginMarketplaceHint() {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(sheetCtx, 'tasks.sidebar.plugins'),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr(sheetCtx, 'tasks.sidebar.pluginsHint'),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: ZInk.faint(sheetCtx),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Official section header + collapse / tidy / refresh.
  Widget _headerRow(BuildContext context, DeviceSession? session) {
    final workspaces = session?.workspaces.length ?? 0;
    final tasks = session == null ? 0 : _totalTaskCount(session);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(context, 'tasks.sectionTitle'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                trP(context, 'tasks.stats', ['$workspaces', '$tasks']),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: ZInk.faint(context)),
              ),
            ],
          ),
        ),
        // Official header actions: the collapse-all button keeps its label
        // and icon in every state (one-way collapse, like the web).
        IconButton(
          tooltip: tr(context, 'tasks.collapseAll'),
          icon: const Icon(Icons.keyboard_double_arrow_up),
          iconSize: 20,
          color: ZInk.muted(context),
          onPressed: () => _collapseAllWorkspaces(session),
        ),
        IconButton(
          tooltip: tr(context, 'tasks.tidy'),
          icon: const Icon(Icons.filter_list),
          iconSize: 20,
          color: ZInk.muted(context),
          onPressed: () => _showTidyPanel(context),
        ),
        IconButton(
          tooltip: tr(context, 'tasks.refreshAll'),
          icon: const Icon(Icons.refresh),
          iconSize: 20,
          color: ZInk.muted(context),
          onPressed: () {
            final s = _session;
            if (s != null) {
              s.reloadTasks();
            } else {
              widget.hub.ensure(widget.device);
            }
          },
        ),
      ],
    );
  }

  /// Official 整理任务 panel: group (workspace / timeline) + sort
  /// (created / updated), radio-style like the web popover.
  Future<void> _showTidyPanel(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                tr(sheetCtx, 'tasks.tidy.groupLabel'),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Column(
              children: [
                for (final (value, label) in [
                  ('workspace', tr(context, 'tasks.tidy.group')),
                  ('timeline', tr(context, 'tasks.tidy.timeline')),
                ])
                  RadioListTile<String>(
                    groupValue: _groupBy,
                    value: value,
                    onChanged: (v) {
                      setState(() => _groupBy = v ?? _groupBy);
                      _saveOrganizePrefs();
                    },
                    title: Text(label),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                    ),
                  ),
              ],
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                tr(sheetCtx, 'tasks.tidy.sortLabel'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ZInk.faint(sheetCtx),
                ),
              ),
            ),
            Column(
              children: [
                for (final (value, label) in [
                  ('created', tr(context, 'tasks.tidy.sort.created')),
                  ('updated', tr(context, 'tasks.tidy.sort.updated')),
                ])
                  RadioListTile<String>(
                    groupValue: _sortBy,
                    value: value,
                    onChanged: (v) {
                      setState(() => _sortBy = v ?? _sortBy);
                      _saveOrganizePrefs();
                    },
                    title: Text(label),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Official "已置顶" group above the workspace cards: one card per pinned
  /// task (title, workspace · time, phase pill).
  List<Widget> _pinnedGroup(BuildContext context, DeviceSession session) {
    final entries = _pinnedEntries(session);
    if (entries.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          tr(context, 'tasks.pinned'),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: ZInk.ghost(context),
          ),
        ),
      ),
      for (final e in entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _pinnedCard(context, session, e),
        ),
    ];
  }

  Widget _pinnedCard(
    BuildContext context,
    DeviceSession session,
    SessionEntry entry,
  ) {
    final (phaseLabel, _) = _phaseVisual(entry.phase);
    final title = entry.title.trim().isEmpty
        ? tr(context, 'tasks.untitled')
        : entry.title;
    final ws =
        _workspaceForKey(
          session,
          entry.raw['workspaceIdentity'] as String? ??
              entry.raw['workspacePath'] as String?,
        ) ??
        session.activeWorkspace;
    final subtitle = [
      if (ws != null) workspaceTitle(ws),
      relativeTimeShort(context, entry.lastActivityAt),
    ].join(' · ');
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: ZInk.hairline(context)),
      ),
      child: InkWell(
        onTap: () => _openWorkspaceTask(session, ws, entry, title),
        onLongPress: () => _taskActions(context, session, entry),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: ZInk.faint(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              PhasePill(label: phaseLabel, phase: entry.phase, solid: true),
            ],
          ),
        ),
      ),
    );
  }

  /// Official 按时间线 grouping: day buckets (今天 / N 天前 / 上周 / 更早)
  /// with one row per task, each prefixed with its workspace name. Covers
  /// every workspace via the relay task list (web mobile-home semantics).
  List<Widget> _timelineGroups(BuildContext context, DeviceSession session) {
    final pairs = _allTaskEntries(session);
    final entries = _sortedEntries([for (final (e, _) in pairs) e]);
    final wsOf = {for (final (e, ws) in pairs) e.sessionId: ws};
    if (entries.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              tr(context, 'tasks.empty'),
              style: TextStyle(fontSize: 13, color: ZInk.faint(context)),
            ),
          ),
        ),
      ];
    }
    final now = DateTime.now();
    final buckets = <String, List<SessionEntry>>{};
    for (final e in entries) {
      buckets
          .putIfAbsent(
            _timelineBucketLabel(context, e.lastActivityAt, now),
            () => [],
          )
          .add(e);
    }
    return [
      for (final bucket in buckets.entries) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
          child: Text(
            bucket.key,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: ZInk.ghost(context),
            ),
          ),
        ),
        for (final e in bucket.value)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _taskRow(
              context,
              session,
              e,
              workspaceLabel: _rowWorkspaceLabel(session, wsOf[e.sessionId]),
            ),
          ),
      ],
    ];
  }

  /// Row prefix label: the task's own workspace (timeline grouping), else
  /// the label handed down by the card.
  String? _rowWorkspaceLabel(DeviceSession session, Map<String, dynamic>? ws) {
    if (ws == null) return null;
    return workspaceTitle(ws);
  }

  /// Official archive view (归档列表): every archived task on the device,
  /// from the relay overview, grouped by workspace. Rows long-press into the
  /// shared action sheet (取消归档 / 删除 live there).
  List<Widget> _archiveView(BuildContext context, DeviceSession session) {
    final widgets = <Widget>[];
    var total = 0;
    for (final ws in session.workspaces) {
      final entries = _sortedEntries(
        _relayEntriesFor(session, ws, archivedOnly: true),
      );
      if (entries.isEmpty) continue;
      total += entries.length;
      widgets
        ..add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
            child: Text(
              workspaceTitle(ws),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: ZInk.ghost(context),
              ),
            ),
          ),
        )
        ..addAll([
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _taskRow(context, session, e, workspace: ws),
            ),
        ]);
    }
    if (total == 0) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: Text(
              tr(context, 'tasks.archive.empty'),
              style: TextStyle(fontSize: 13, color: ZInk.faint(context)),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  /// Official bucket labels (web taskTimeline): today / yesterday /
  /// day-count / last week / earlier.
  String _timelineBucketLabel(BuildContext context, int millis, DateTime now) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    final diff = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff <= 0) return tr(context, 'tasks.timeline.today');
    if (diff == 1) return tr(context, 'tasks.timeline.yesterday');
    if (diff <= 6) return trP(context, 'tasks.timeline.daysAgo', ['$diff']);
    if (diff <= 13) return tr(context, 'tasks.timeline.lastWeek');
    return tr(context, 'tasks.timeline.earlier');
  }

  /// One workspace card: name + 本地 badge, folder + path, updated-at, task
  /// count + chevron + new-task button; expanded shows the task rows.
  Widget _workspaceCard(
    BuildContext context,
    DeviceSession session,
    Map<String, dynamic> ws,
  ) {
    final isActive = _isWorkspaceActive(session, ws);
    final key = workspaceKeyOf(ws) ?? workspaceTitle(ws);
    final expanded = _isWorkspaceExpanded(key, isActive: isActive);

    final sessions = isActive ? session.sessions : null;
    // Active workspace: the live sessions-index (richer phase/interaction).
    // Others: the relay task overview — the web mobile home does the same.
    var entries = sessions?.ready == true
        ? sessions!.list
        : _relayEntriesFor(session, ws);
    entries = [
      for (final e in entries)
        if (e.raw['archived'] != true) e,
    ];
    entries = _sortedEntries(entries);
    final lastActivity = entries.isEmpty
        ? null
        : entries.map((e) => e.lastActivityAt).reduce((a, b) => a > b ? a : b);
    // Official highlight: the "current" task row (latest running, else the
    // most recently active) gets a rounded white/10 background.
    final current = _currentEntry(entries);

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: ZInk.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            // mobile home: expand/collapse only — opening happens on task taps
            onTap: () => _toggleWorkspace(session, ws, openIfInactive: false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                workspaceTitle(ws),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            _kindBadge(context, ws),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.folder_outlined,
                              size: 13,
                              color: ZInk.ghost(context),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '${ws['workspacePath'] ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: ZInk.faint(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (lastActivity != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            trP(context, 'tasks.updatedAt', [
                              relativeTimeShort(context, lastActivity),
                            ]),
                            style: TextStyle(
                              fontSize: 11,
                              color: ZInk.ghost(context),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isActive || entries.isNotEmpty)
                    Text(
                      trP(context, 'tasks.taskCount', ['${entries.length}']),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: ZInk.faint(context),
                      ),
                    ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 20,
                    color: ZInk.ghost(context),
                  ),
                  const SizedBox(width: 4),
                  _newTaskButton(context, session, workspace: isActive ? null : ws),
                ],
              ),
            ),
          ),
          if (expanded &&
              (isActive ? sessions != null : entries.isNotEmpty)) ...[
            Divider(height: 1, color: ZInk.hairline(context)),
            if (isActive && sessions != null && !sessions.ready)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Text(
                    tr(context, 'tasks.empty'),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: ZInk.faint(context),
                    ),
                  ),
                ),
              )
            else
              for (var i = 0; i < entries.length; i++)
                _taskRow(
                  context,
                  session,
                  entries[i],
                  highlight:
                      current != null &&
                      entries[i].sessionId == current.sessionId,
                  workspace: isActive ? null : ws,
                ),
          ],
        ],
      ),
    );
  }

  /// The row the official page highlights: the latest running task, falling
  /// back to the most recently active one.
  static SessionEntry? _currentEntry(List<SessionEntry> entries) {
    SessionEntry? current;
    for (final e in entries) {
      final running = e.phase == 'running' || e.phase == 'prewarming';
      if (running &&
          (current == null || e.lastActivityAt > current.lastActivityAt)) {
        current = e;
      }
    }
    if (current != null || entries.isEmpty) return current;
    return entries.reduce(
      (a, b) => a.lastActivityAt > b.lastActivityAt ? a : b,
    );
  }

  /// Workspace-kind badge (web `workspaceKind.local/conversation/remote`).
  Widget _kindBadge(BuildContext context, Map<String, dynamic> ws) {
    final purpose = ws['workspacePurpose'];
    final kind = purpose == 'conversation'
        ? 'conversation'
        : (ws['kind'] == 'remote' ? 'remote' : 'local');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: ZInk.tile(context),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        tr(context, 'tasks.workspaceKind.$kind'),
        style: TextStyle(fontSize: 10, color: ZInk.faint(context)),
      ),
    );
  }

  /// ➕ starts a draft chat (createSession fires on first send). In a
  /// non-active workspace card it re-points the bridge first so the draft
  /// lands in that workspace.
  Widget _newTaskButton(
    BuildContext context,
    DeviceSession session, {
    Map<String, dynamic>? workspace,
  }) {
    final newLabel = tr(context, 'tasks.new');
    Future<void> start() async {
      if (workspace != null && !_isWorkspaceActive(session, workspace)) {
        await session.openWorkspace(workspace);
      }
      if (!mounted) return;
      await _openChat(title: newLabel);
    }

    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        tooltip: newLabel,
        padding: EdgeInsets.zero,
        icon: Icon(
          Icons.add_circle_outline,
          size: 20,
          color: ZInk.muted(context),
        ),
        onPressed: start,
      ),
    );
  }

  /// One task row: title + phase pill + relative time. No per-row overflow
  /// button (official mobile parity) — a long press opens the action sheet.
  /// The current (latest running / most recent) row gets the official
  /// rounded white/10 highlight. Rows of other workspaces carry [workspace]
  /// so opening them re-points the bridge (web: workspace-bridge-open with
  /// taskId). Official tags: 「等待确认」(pending interaction) and the
  /// unread dot (`unreadAt`).
  Widget _taskRow(
    BuildContext context,
    DeviceSession session,
    SessionEntry entry, {
    bool highlight = false,
    String? workspaceLabel,
    Map<String, dynamic>? workspace,
  }) {
    final (phaseLabel, _) = _phaseVisual(entry.phase);
    final title = entry.title.trim().isEmpty
        ? tr(context, 'tasks.untitled')
        : entry.title;
    final subtitle = [
      if (workspaceLabel != null) workspaceLabel,
      relativeTimeShort(context, entry.lastActivityAt),
    ].join(' · ');
    final awaiting = entry.pendingInteraction != null;
    final unread = entry.raw['unreadAt'] != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: highlight
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _openWorkspaceTask(session, workspace, entry, title),
          onLongPress: () => _taskActions(context, session, entry),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 62),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (unread) ...[
                              Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                  color: ZColors.sky500,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: unread
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (awaiting) ...[
                              _awaitingTag(context),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: ZInk.faint(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  PhasePill(label: phaseLabel, phase: entry.phase, solid: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Official `permissionTag`/`userInputTag`: 「等待确认」amber mini-pill.
  Widget _awaitingTag(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: ZColors.warning.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        tr(context, 'tasks.awaiting'),
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w500,
          color: ZColors.warning,
        ),
      ),
    );
  }

  /// Opens a task row whatever workspace it lives in: tasks of the active
  /// workspace go straight to chat; others re-point the bridge first
  /// (workspace-bridge-open rides the taskId, web parity).
  Future<void> _openWorkspaceTask(
    DeviceSession session,
    Map<String, dynamic>? workspace,
    SessionEntry entry,
    String title,
  ) async {
    if (workspace != null && !_isWorkspaceActive(session, workspace)) {
      await session.openWorkspace(workspace, taskId: entry.sessionId);
    }
    if (!mounted) return;
    await _openChat(
      sessionId: entry.sessionId,
      title: title,
      pinned: entry.raw['pinned'] == true,
    );
  }

  /// Long-press action sheet, official task-item menu parity:
  /// 停止/暂停/继续 (phase-gated) + 置顶 / 重命名 / 归档 / 标记未读 / 删除.
  /// Delete carries the official confirm dialog (records cannot be
  /// recovered). Metadata ops run on the zcode-task channel and refresh the
  /// list (the relay also pushes workspace-list-updated).
  Future<void> _taskActions(
    BuildContext context,
    DeviceSession session,
    SessionEntry entry,
  ) async {
    final running = entry.phase == 'running' || entry.phase == 'prewarming';
    final paused = entry.phase.toLowerCase().contains('pause');
    final pinned = entry.raw['pinned'] == true;
    final archived = entry.raw['archived'] == true;
    final unread = entry.raw['unreadAt'] != null;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.stop_circle_outlined),
                title: Text(tr(sheetCtx, 'tasks.stop')),
                enabled: running,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() => session.stopTask(entry.sessionId));
                },
              ),
              ListTile(
                leading: const Icon(Icons.pause_circle_outline),
                title: Text(tr(sheetCtx, 'tasks.pause')),
                enabled: running,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() => session.pauseTask(entry.sessionId));
                },
              ),
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text(tr(sheetCtx, 'tasks.resume')),
                enabled: paused,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() => session.resumeTask(entry.sessionId));
                },
              ),
              ListTile(
                leading: Icon(
                  pinned ? Icons.push_pin_outlined : Icons.push_pin_outlined,
                ),
                title: Text(
                  tr(
                    sheetCtx,
                    pinned ? 'tasks.action.unpin' : 'tasks.action.pin',
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() async {
                    await session.setTaskPinned(entry.sessionId, !pinned);
                    await session.reloadTasks();
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: Text(tr(sheetCtx, 'tasks.action.rename')),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _renameTaskDialog(session, entry);
                },
              ),
              ListTile(
                leading: archived
                    ? const Icon(Icons.unarchive_outlined)
                    : const Icon(Icons.archive_outlined),
                title: Text(
                  tr(
                    sheetCtx,
                    archived
                        ? 'tasks.action.unarchive'
                        : 'tasks.action.archive',
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() async {
                    await session.setTaskArchived(entry.sessionId, !archived);
                    await session.reloadTasks();
                  });
                },
              ),
              ListTile(
                leading: Icon(
                  unread
                      ? Icons.mark_email_read_outlined
                      : Icons.mark_email_unread_outlined,
                ),
                title: Text(
                  tr(
                    sheetCtx,
                    unread
                        ? 'tasks.action.markRead'
                        : 'tasks.action.markUnread',
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _runOp(() async {
                    await session.setTaskUnread(entry.sessionId, !unread);
                    await session.reloadTasks();
                  });
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: ZColors.danger,
                ),
                title: Text(
                  tr(sheetCtx, 'tasks.action.delete'),
                  style: const TextStyle(color: ZColors.danger),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _deleteTaskDialog(session, entry);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Official task-rename flow (inline on web; modal here) — placeholder
  /// 「任务名称」.
  Future<void> _renameTaskDialog(
    DeviceSession session,
    SessionEntry entry,
  ) async {
    final controller = TextEditingController(text: entry.title);
    final title = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(tr(dialogCtx, 'tasks.action.rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: tr(dialogCtx, 'tasks.renamePlaceholder'),
          ),
          onSubmitted: (v) => Navigator.of(dialogCtx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(tr(dialogCtx, 'common.cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogCtx).pop(controller.text.trim()),
            child: Text(tr(dialogCtx, 'common.save')),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty || title == entry.title) return;
    await _runOp(() async {
      await session.renameTask(entry.sessionId, title);
      await session.reloadTasks();
    });
  }

  /// Official delete confirmation:
  /// 「删除这个任务？…会从当前工作区移除，现有记录无法恢复。」
  Future<void> _deleteTaskDialog(
    DeviceSession session,
    SessionEntry entry,
  ) async {
    final title = entry.title.trim().isEmpty
        ? tr(context, 'tasks.untitled')
        : entry.title;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(tr(dialogCtx, 'tasks.action.deleteTitle')),
        content: Text(trP(dialogCtx, 'tasks.action.deleteDesc', [title])),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(tr(dialogCtx, 'common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(tr(dialogCtx, 'tasks.action.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runOp(() async {
      await session.deleteTask(entry.sessionId);
      await session.reloadTasks();
      if (_paneSessionId == entry.sessionId) {
        setState(() {
          _paneSessionId = null;
          _paneTitle = null;
        });
      }
    });
  }

  /// Opens a task chat. On ≥768px the chat lands in the right pane (the
  /// native connection STAYS live — one sid, one terminal, and we are it);
  /// on phones it pushes the full-screen page. Falls back to the WebView
  /// deep link when no protocol session exists.
  Future<void> _openChat({
    String? sessionId,
    required String title,
    String? initialComposerText,
    bool pinned = false,
  }) async {
    final session = _session;
    if (session == null || session.status == DeviceStatus.disconnected) {
      await _openRemote(targetSessionId: sessionId, targetTitle: title);
      return;
    }
    await widget.store.touch(widget.device.id);
    if (!mounted) return;
    if (MediaQuery.sizeOf(context).width >= kDualPaneBreakpoint) {
      setState(() {
        _paneSessionId = sessionId;
        _paneTitle = title;
        _paneInitialComposerText = initialComposerText;
        _panePinned = pinned;
      });
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          gateway: session,
          sessionId: sessionId,
          title: title,
          theme: widget.theme,
          initialComposerText: initialComposerText,
          initialPinned: pinned,
          workspaceLabel: session.activeWorkspace != null
              ? workspaceTitle(session.activeWorkspace!)
              : null,
        ),
      ),
    );
  }

  /// WebView fallback (overflow menu): suspend the native connection, open
  /// the remote page deep-linked to a session, resume ~1s after it pops.
  Future<void> _openRemote({
    String? targetSessionId,
    String? targetTitle,
  }) async {
    await widget.store.touch(widget.device.id);
    await widget.hub.suspend(widget.device.id);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RemotePage(
          device: widget.device,
          targetSessionId: targetSessionId,
          targetTitle: targetTitle,
        ),
      ),
    );
    widget.hub.scheduleResume(widget.device);
  }

  Future<void> _runOp(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(trP(context, 'tasks.opFailed', ['$e']))),
      );
    }
  }

  void _onMenu(String v) {
    final session = _session;
    switch (v) {
      case 'archive':
        setState(() => _showArchived = !_showArchived);
      case 'deskSet':
        if (session == null) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DesktopSettingsPage(session: session),
        ));
      case 'usage':
        if (session == null) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => DeviceUsagePage(session: session)),
        );
      case 'providers':
        if (session == null) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ModelProvidersPage(session: session),
          ),
        );
      case 'automations':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AutomationsPage(
              store: widget.store,
              hub: widget.hub,
              initialDeviceId: widget.device.id,
            ),
          ),
        );
      case 'offPeak':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => OffPeakPage(
              store: widget.store,
              hub: widget.hub,
              device: widget.device,
            ),
          ),
        );
      case 'web':
        _openRemote();
    }
  }

  Widget _fallback(BuildContext context, DeviceSession? session) {
    final error = session?.error;
    final connecting =
        session != null &&
        session.status != DeviceStatus.error &&
        session.status != DeviceStatus.disconnected &&
        (session.status == DeviceStatus.connecting || session.openingWorkspace);
    if (connecting) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Column(
            children: [
              const CircularProgressIndicator(strokeWidth: 2),
              const SizedBox(height: 16),
              Text(
                tr(context, 'tasks.loading'),
                style: TextStyle(fontSize: 13, color: ZInk.faint(context)),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.cloud_off, size: 44, color: ZInk.ghost(context)),
            const SizedBox(height: 16),
            Text(
              tr(context, 'tasks.fallback.title'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: ZInk.solid(context),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error ?? tr(context, 'tasks.fallback.body'),
              textAlign: TextAlign.center,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: ZInk.faint(context)),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _openRemote(),
              child: Text(tr(context, 'tasks.openWeb')),
            ),
          ],
        ),
      ),
    );
  }

  (String, Color) _phaseVisual(String phase) {
    switch (phase) {
      case 'running':
        return (tr(context, 'phase.running'), ZColors.sky500);
      case 'prewarming':
        return (tr(context, 'phase.prewarming'), ZColors.sky400);
      case 'completedSuccess':
        return (tr(context, 'phase.completedSuccess'), ZColors.success);
      case 'completedInterrupted':
        return (tr(context, 'phase.completedInterrupted'), ZColors.neutral500);
      case 'error':
        return (tr(context, 'phase.error'), ZColors.danger);
      case 'draft':
        return (tr(context, 'phase.draft'), ZColors.neutral400);
      case 'idle':
        return (tr(context, 'phase.idle'), ZColors.neutral400);
      default:
        if (phase.toLowerCase().contains('pause')) {
          return (tr(context, 'phase.paused'), ZColors.neutral500);
        }
        return (phase, ZColors.neutral400);
    }
  }
}

/// Connection status card at the top of the list (official mobile layout).
/// Always visible: the healthy link shows the green online state plus the
/// explanation copy; degraded states add retry + web fallback actions.
class _ConnectionBanner extends StatelessWidget {
  final DeviceSession? session;
  final Future<void> Function() onWeb;

  const _ConnectionBanner({required this.session, required this.onWeb});

  /// Official failure-state copy (`webRemoteControl.failure.*`): a
  /// well-known app-error/close-code reason maps to the same localized text
  /// the web page shows; unknown reasons fall back to the raw error.
  static String _failureBody(BuildContext context, DeviceSession s) {
    final reason = s.failureReason;
    if (reason != null) {
      final localized = tr(context, 'remote.failure.$reason');
      if (localized != 'remote.failure.$reason') return localized;
    }
    return s.error ?? tr(context, 'tasks.fallback.body');
  }

  bool get _online =>
      session != null &&
      session!.status == DeviceStatus.connected &&
      !session!.kicked &&
      (session!.error?.isEmpty ?? true);

  @override
  Widget build(BuildContext context) {
    if (_online) return _onlineCard(context);
    return _degradedCard(context);
  }

  /// Official online state: explanation card only (title + green subtitle
  /// already live in the mobile AppBar).
  Widget _onlineCard(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: ZInk.hairline(context)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          tr(context, 'tasks.banner.onlineDesc'),
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: ZInk.faint(context),
          ),
        ),
      ),
    );
  }

  Widget _degradedCard(BuildContext context) {
    final s = session;
    String title;
    String body;
    IconData icon;
    Color color;
    if (s == null) {
      title = tr(context, 'status.offline');
      body = tr(context, 'tasks.banner.nativeOff');
      icon = Icons.cloud_off;
      color = ZColors.neutral400;
    } else if (s.kicked) {
      title = tr(context, 'status.kicked');
      body = tr(context, 'tasks.banner.kicked');
      icon = Icons.phonelink_erase_outlined;
      color = ZColors.danger;
    } else if (s.status == DeviceStatus.connecting) {
      title = tr(context, 'status.connecting');
      body = tr(context, 'tasks.banner.connecting');
      icon = Icons.sync;
      color = ZColors.sky400;
    } else {
      title = tr(context, 'tasks.fallback.title');
      body = _failureBody(context, s);
      icon = Icons.cloud_off;
      color = ZColors.danger;
    }
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: ZInk.hairline(context)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ZInk.solid(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: ZInk.faint(context)),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Flexible(
                        child: FilledButton.tonal(
                          onPressed: () {
                            final s2 = session;
                            if (s2 != null) {
                              s2.reloadTasks();
                            }
                          },
                          child: Text(
                            tr(context, 'tasks.retry'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: TextButton(
                          onPressed: onWeb,
                          child: Text(
                            tr(context, 'tasks.openWeb'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
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
