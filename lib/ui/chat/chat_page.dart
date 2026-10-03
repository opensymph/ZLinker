import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../protocol/conversation.dart';
import '../../state/device_session.dart';
import '../theme.dart';
import '../ui_settings.dart';
import 'chat_input.dart';
import 'chat_interactions.dart';
import 'chat_bubbles.dart';
import 'chat_message_list.dart';
import 'chat_panels.dart';
import 'chat_sheets.dart';
import 'mention_sheet.dart';
import 'session_sheets.dart';

/// Native chat view for one task (session), backed by Conversation V4 over
/// [ChatGateway]. Draft mode (no [sessionId]): the first message issues
/// `createSession` with the draft model/mode/thought config.
class ChatPage extends StatefulWidget {
  final ChatGateway gateway;
  final String? sessionId;
  final String title;
  final ThemeController? theme;

  /// Dual-pane desktop layout: embedded in the right pane, so no back
  /// button in the app bar (there is no route to pop inside the pane).
  final bool embedded;

  /// Read-only transcript view (workflow actor sessions): the message
  /// stream renders but the composer/send surface is hidden entirely.
  final bool readOnly;

  /// Pre-fill the composer (e.g. a slash command picked on the list page).
  final String? initialComposerText;

  /// Optional workspace chip shown next to the task title (official chat
  /// second header row).
  final String? workspaceLabel;

  /// Pinned state of the opened task (from the list entry) so the 更多 menu
  /// can show 置顶任务 / 取消置顶任务 like the web and toggle it.
  final bool initialPinned;

  const ChatPage({
    super.key,
    required this.gateway,
    this.sessionId,
    required this.title,
    this.theme,
    this.embedded = false,
    this.readOnly = false,
    this.initialComposerText,
    this.workspaceLabel,
    this.initialPinned = false,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  ChatHandle? _handle;
  bool _subscribing = false;
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  String? _sessionId;
  String? _error;
  bool _sending = false;
  bool _loadingOlder = false;
  bool _showSlash = false;

  /// @-mention picker state (see _maybeOpenMentionPicker).
  bool _mentionOpen = false;
  int _mentionTriggerEnd = 0;
  bool get _mentionEnabled => true;
  String? _progress;
  final List<PendingFile> _pendingFiles = [];
  double? _uploadProgress;
  WorkspacePrep? _prep;
  List<SkillEntry> _skills = [];
  bool _skillsLoading = false;

  /// Draft-mode (no session yet) model/mode/thought selection, passed as
  /// `config` to createSession on first send.
  final Map<String, String> _draftConfig = {};

  /// Whether to keep the view pinned to the newest message. Starts true so
  /// opening the chat lands at the bottom; the user scrolling up unpins it.
  bool _stickToBottom = true;

  /// Mirrors [ChatPage.initialPinned]; flips when the 更多 pin toggle runs.
  bool _pinned = false;

  // ── in-chat find (web useConversationTimelineFind parity) ──
  bool _searchOpen = false;
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _searchQuery = '';

  /// firstRowId of every turn group with a match (stable across history
  /// prepends, unlike group indices).
  List<int> _searchHitRowIds = [];
  int _searchCursor = -1;
  bool _searchAutoLoading = false;

  /// web FIND_AUTO_LOAD_ROW_LIMIT: keep pulling older rows while a search
  /// has no hit, up to this many loaded rows.
  static const int _kSearchAutoLoadRowLimit = 1200;

  // ── turn navigator rail (web ConversationTurnNavigator parity) ──
  final Map<String, GlobalObjectKey> _turnKeys = {};
  Timer? _visibleTurnTimer;
  int _visibleTurn = 0;

  GlobalObjectKey _turnKeyFor(int firstRowId) => _turnKeys.putIfAbsent(
        '$_sessionId/$firstRowId',
        () => GlobalObjectKey('turn.$_sessionId.$firstRowId'),
      );

  ConversationState? get _state => _handle?.state;

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId;
    _pinned = widget.initialPinned;
    final initial = widget.initialComposerText;
    if (initial != null && initial.isNotEmpty) {
      _inputController.text = initial;
    }
    _scrollController.addListener(_onScroll);
    if (_sessionId != null) {
      _subscribe();
    }
    _loadPrep();
    _inputController.addListener(() {
      final text = _inputController.text;
      final show = (text.startsWith('/') || text.startsWith('\$')) &&
          !text.contains(' ');
      if (show != _showSlash && mounted) {
        setState(() => _showSlash = show);
      }
      _maybeOpenMentionPicker(text);
    });
  }

  /// Web @-mention parity: typing `@` at word start opens the mention
  /// picker; the picked reference replaces the trigger and gets a trailing
  /// space. Debounced by the sheet-open flag.
  void _maybeOpenMentionPicker(String text) {
    if (_mentionOpen || !_mentionEnabled) return;
    final sel = _inputController.selection;
    if (!sel.isValid) return;
    final i = sel.baseOffset;
    if (i < 1 || i > text.length) return;
    if (text[i - 1] != '@') return;
    const newlines = '\n';
    final atWordStart = i == 1 || text[i - 2] == ' ' || text[i - 2] == newlines;
    if (!atWordStart) return;
    _mentionOpen = true;
    _mentionTriggerEnd = i;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final entry = await showMentionSheet(context, widget.gateway);
      _mentionOpen = false;
      if (!mounted || entry == null) return;
      final start =
          (_mentionTriggerEnd - 1).clamp(0, _inputController.text.length);
      final next = applyMentionInsert(
          _inputController.text, _mentionTriggerEnd, entry.insert);
      _inputController.value = TextEditingValue(
        text: next,
        selection:
            TextSelection.collapsed(offset: start + entry.insert.length + 2),
      );
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    _stickToBottom = _scrollController.position.pixels >= max - 40;
    // Debounced active-turn tracking for the navigator rail.
    _visibleTurnTimer?.cancel();
    _visibleTurnTimer = Timer(
      const Duration(milliseconds: 150),
      _updateVisibleTurn,
    );
  }

  Future<void> _loadPrep() async {
    try {
      final prep = await widget.gateway.prepareWorkspace();
      if (mounted) setState(() => _prep = prep);
    } catch (_) {}
    if (mounted) setState(() => _skillsLoading = true);
    try {
      final skills = await widget.gateway.skills();
      if (mounted) setState(() => _skills = skills);
    } catch (_) {
      if (mounted) setState(() => _skills = const []);
    } finally {
      if (mounted) setState(() => _skillsLoading = false);
    }
  }

  @override
  void dispose() {
    // mobile-view-state back to workspace-only (the phone left this task).
    try {
      widget.gateway.sendViewState();
    } catch (_) {}
    unawaited(_saveDraft());
    _handle?.close();
    _inputController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    _visibleTurnTimer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------- in-chat find & jumps

  static int _rowIdOf(Map row) => (row['rowId'] as num?)?.toInt() ?? 0;

  void _openSearch() {
    setState(() => _searchOpen = true);
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    setState(() {
      _searchOpen = false;
      _searchQuery = '';
      _searchHitRowIds = [];
      _searchCursor = -1;
    });
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      _submitSearch(value);
    });
  }

  void _submitSearch([String? value]) {
    final q = (value ?? _searchController.text).trim();
    _searchQuery = q;
    if (q.isEmpty) {
      if (mounted) {
        setState(() {
          _searchHitRowIds = [];
          _searchCursor = -1;
        });
      }
      return;
    }
    _reindexSearch();
    if (mounted) setState(() {});
    if (_searchHitRowIds.isEmpty) _autoLoadForSearch();
  }

  /// Rebuilds the hit list over the currently loaded rows, matching only
  /// user/assistant text rows (web conversationFindIndex).
  void _reindexSearch() {
    final state = _state;
    if (state == null) return;
    final q = _searchQuery.toLowerCase();
    if (q.isEmpty) {
      _searchHitRowIds = [];
      _searchCursor = -1;
      return;
    }
    final hits = <int>[];
    for (final group in groupTurnRows(state.rows)) {
      for (final row in group) {
        final kind = row['kind'];
        if (kind != 'userInput' && kind != 'assistantText') continue;
        if ('${row['text'] ?? ''}'.toLowerCase().contains(q)) {
          hits.add(_rowIdOf(group.first));
          break;
        }
      }
    }
    _searchHitRowIds = hits;
    _searchCursor = hits.isEmpty ? -1 : 0;
  }

  /// Keeps pulling older rows while the search has no hit (web
  /// FIND_AUTO_LOAD_ROW_LIMIT), so find covers the whole conversation.
  Future<void> _autoLoadForSearch() async {
    final state = _state;
    if (state == null || _searchAutoLoading) return;
    _searchAutoLoading = true;
    try {
      while (mounted &&
          _searchQuery.isNotEmpty &&
          _searchHitRowIds.isEmpty &&
          state.canLoadOlder &&
          state.rows.length < _kSearchAutoLoadRowLimit) {
        await _loadOlder();
        _reindexSearch();
        if (mounted) setState(() {});
      }
    } finally {
      _searchAutoLoading = false;
    }
  }

  Future<void> _gotoSearchHit(int step) async {
    if (_searchHitRowIds.isEmpty) return;
    final n = _searchHitRowIds.length;
    _searchCursor = ((_searchCursor + step) % n + n) % n;
    if (mounted) setState(() {});
    await _jumpToTurnRowId(_searchHitRowIds[_searchCursor]);
  }

  /// Jumps the list so the turn group opening with [firstRowId] is visible.
  Future<void> _jumpToTurnRowId(int firstRowId) async {
    final state = _state;
    if (state == null) return;
    final groups = groupTurnRows(state.rows);
    final index = groups
        .indexWhere((g) => g.isNotEmpty && _rowIdOf(g.first) == firstRowId);
    if (index < 0) return;
    _stickToBottom = false;
    final key = _turnKeyFor(firstRowId);
    var ctx = key.currentContext;
    if (ctx == null) {
      // ListView.builder hasn't built that far: jump near it by estimated
      // extent, then align precisely once the item exists.
      final count = groups.length + (state.canLoadOlder ? 1 : 0);
      final max = _scrollController.hasClients
          ? _scrollController.position.maxScrollExtent
          : 0.0;
      if (max > 0 && count > 0) {
        final estimated = (index * (max / count)).clamp(0.0, max);
        _scrollController.jumpTo(estimated);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        ctx = key.currentContext;
      }
    }
    final elementCtx = ctx;
    if (elementCtx != null && elementCtx.mounted) {
      await Scrollable.ensureVisible(
        elementCtx,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        alignment: 0.05,
      );
    }
    if (mounted) setState(() => _visibleTurn = index);
  }

  /// Tracks which turn group is on screen for the navigator rail.
  void _updateVisibleTurn() {
    final state = _state;
    if (state == null || !mounted) return;
    final groups = groupTurnRows(state.rows);
    if (groups.length < 4) {
      if (_visibleTurn != 0) setState(() => _visibleTurn = 0);
      return;
    }
    final center = MediaQuery.sizeOf(context).height * 0.4;
    var active = 0;
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].isEmpty) continue;
      final box = _turnKeyFor(_rowIdOf(groups[i].first))
          .currentContext
          ?.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) {
        if (box.localToGlobal(Offset.zero).dy <= center) active = i;
      }
    }
    if (active != _visibleTurn) setState(() => _visibleTurn = active);
  }

  Future<void> _subscribe() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    if (_subscribing) return;
    _subscribing = true;
    try {
      // Open-then-load: the workspace bridge may still be coming up in the
      // background (tap-opens-immediately flow) — retry instead of surfacing
      // an error, so the conversation self-heals once the relay is ready.
      Object? lastError;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final handle = await widget.gateway
              .subscribe(sessionId)
              .timeout(const Duration(seconds: 60));
          if (!mounted) {
            await handle.close();
            return;
          }
          setState(() {
            _handle = handle;
            _error = null;
          });
          // mobile-view-state: the desktop shows 「手机正在操作此任务」 from it.
          widget.gateway.sendViewState(taskId: sessionId);
          handle.state.addListener(_scrollToBottom);
          unawaited(_restoreDraft(sessionId));
          // The server snapshot is a tail window (can be as few as 3 rows).
          // The official client shows the full history immediately, so
          // auto-load the missing older rows once on open.
          if (handle.state.canLoadOlder) {
            await _loadOlder();
          }
          // Explicitly position at the newest message: the state listener
          // only fires on LATER updates and misses the initial snapshot.
          _scrollToBottom();
          return;
        } catch (e) {
          lastError = e;
          if (mounted && attempt < 2) {
            setState(() => _error = '$e');
          }
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
      if (mounted && lastError != null) setState(() => _error = '$lastError');
    } finally {
      _subscribing = false;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      // Snap to the newest message on open; afterwards only follow while the
      // user is already near the bottom (so reading history isn't yanked).
      if (_stickToBottom || _scrollController.position.pixels > max - 400) {
        _scrollController.animateTo(
          max,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _run(String errorPrefix, Future<dynamic> Function() run) async {
    try {
      final res = await run();
      if (res is Map &&
          res['status'] != null &&
          res['status'] != 'accepted' &&
          res['status'] != 'noop') {
        _toast('$errorPrefix: ${res['reasonCode'] ?? res['status']}');
      }
    } catch (e) {
      final business =
          businessErrorCopy('$e', () => tr(context, 'common.retryLater'));
      _toast(business ?? '$errorPrefix: $e');
    }
  }

  // ------------------------------------------------------------ sending

  String _guessMime(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'svg' => 'image/svg+xml',
      'pdf' => 'application/pdf',
      'txt' || 'md' || 'log' => 'text/plain',
      'json' => 'application/json',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.pickFiles(
        withData: true,
        allowMultiple: true,
      );
      if (result == null) return;
      setState(() {
        for (final file in result.files) {
          final bytes = file.bytes;
          if (bytes == null) continue;
          _pendingFiles.add(
            PendingFile(file.name, _guessMime(file.name), bytes),
          );
        }
      });
    } catch (e) {
      if (mounted) _toast(trP(context, 'chat.attach.pickFailed', ['$e']));
    }
  }

  Future<List<Map<String, dynamic>>> _uploadPending(String sessionId) async {
    final uploaded = <Map<String, dynamic>>[];
    for (var i = 0; i < _pendingFiles.length; i++) {
      final file = _pendingFiles[i];
      final descriptor = await widget.gateway.attachmentPut(
        sessionId,
        fileName: file.fileName,
        mime: file.mime,
        bytes: file.bytes,
        onProgress: (p) =>
            setState(() => _uploadProgress = (i + p) / _pendingFiles.length),
      );
      uploaded.add(descriptor);
    }
    return uploaded;
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if ((text.isEmpty && _pendingFiles.isEmpty) || _sending) return;

    // Slash commands (mirrors the web composer).
    if (text == '/compact' || text.startsWith('/compact ')) {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.compact.failed'),
        () => widget.gateway.compact(_requireSession()),
      );
      return;
    }
    if (text == '/goal pause') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.goal.pauseFailed'),
        () => widget.gateway.pauseGoal(_requireSession()),
      );
      return;
    }
    if (text == '/goal resume') {
      _inputController.clear();
      setState(() => _showSlash = false);
      await _run(
        tr(context, 'chat.goal.resumeFailed'),
        () => widget.gateway.resumeGoal(_requireSession()),
      );
      return;
    }

    // held-queue confirmation: when inputRouting is `choice` the user
    // picks whether to clear the held queue or keep it.
    String? heldDisposition;
    final state = _state;
    if (state != null &&
        state.inputRoutingMode == 'choice' &&
        state.queueItems.isNotEmpty) {
      heldDisposition = await _askHeldQueueDisposition();
      if (heldDisposition == null) return; // cancelled
      if (!mounted) return;
    }

    setState(() {
      _sending = true;
      _uploadProgress = null;
      _showSlash = false;
      _progress = null;
    });
    try {
      var sessionId = _sessionId;
      if (sessionId == null) {
        // 1) create the session (can take a while when the runtime warms)
        setState(() => _progress = tr(context, 'chat.creating'));
        // Plain text first message is sent WITH createSession (firstInput,
        // mirrors the official composer). This avoids a send-before-subscribe
        // race where the first command can be dropped on a fresh session.
        final canUseFirstInput = text.isNotEmpty &&
            _pendingFiles.isEmpty &&
            !text.startsWith('/goal ') &&
            heldDisposition == null;
        final workspaceId = widget.gateway.chatWorkspaceId;
        if (workspaceId == null || workspaceId.isEmpty) {
          throw StateError(tr(context, 'tasks.noWorkspaces.title'));
        }
        sessionId = await widget.gateway.createSession(
          workspaceId,
          firstText: canUseFirstInput ? text : null,
          config: _buildDraftConfig(),
        );
        if (!mounted) return;
        _sessionId = sessionId;
        // 2) subscribe in the background — must NOT block sending
        setState(() => _progress = null);
        if (canUseFirstInput) {
          // Message already sent with the session; just display history.
          _inputController.clear();
          setState(() => _pendingFiles.clear());
          unawaited(_recordInputHistory(text));
          _subscribe();
          return;
        }
        // Attachments / goal commands: the follow-up command needs an active
        // subscription, so wait for it before proceeding.
        await _subscribe();
      }
      if (text.startsWith('/goal ')) {
        final res = await widget.gateway.sendGoalCommand(
          sessionId,
          text.substring('/goal '.length).trim(),
          heldQueueDisposition: heldDisposition,
        );
        if (_ackRejected(res)) {
          if (mounted) {
            _toast(trP(context, 'chat.send.failed', [_ackReason(res)]));
          }
          return;
        }
        _inputController.clear();
        return;
      }
      List<Map<String, dynamic>>? attachments;
      if (_pendingFiles.isNotEmpty) {
        setState(() => _progress = tr(context, 'chat.attach.uploading'));
        attachments = await _uploadPending(sessionId);
        setState(() => _progress = null);
      }
      final res = await widget.gateway.sendText(
        sessionId,
        text,
        attachments: attachments,
        heldQueueDisposition: heldDisposition,
      );
      if (_ackRejected(res)) {
        if (mounted) {
          _toast(trP(context, 'chat.send.failed', [_ackReason(res)]));
        }
        return;
      }
      _inputController.clear();
      setState(() => _pendingFiles.clear());
      if (text.isNotEmpty) unawaited(_recordInputHistory(text));
    } catch (e) {
      if (mounted) _toast(trP(context, 'chat.send.failed', ['$e']));
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _uploadProgress = null;
          _progress = null;
        });
      }
    }
  }

  bool _ackRejected(dynamic res) =>
      res is Map &&
      res['status'] != null &&
      res['status'] != 'accepted' &&
      res['status'] != 'noop' &&
      res['status'] != 'duplicate';

  String _ackReason(dynamic res) {
    if (res is! Map) return '$res';
    return '${res['reasonCode'] ?? res['message'] ?? res['status']}';
  }

  String _requireSession() {
    final sessionId = _sessionId;
    if (sessionId == null) throw StateError(tr(context, 'chat.noSession'));
    return sessionId;
  }

  /// Builds the createSession `config` payload from the draft selection.
  Map<String, dynamic>? _buildDraftConfig() {
    if (_draftConfig.isEmpty) return null;
    final config = <String, dynamic>{};
    final modelValue = _draftConfig['model'];
    if (modelValue != null && modelValue.isNotEmpty) {
      final idx = modelValue.lastIndexOf('/');
      if (idx > 0) {
        config['provider'] = modelValue.substring(0, idx);
        config['model'] = modelValue.substring(idx + 1);
      }
    }
    if (_draftConfig['thought'] != null) {
      config['thought'] = _draftConfig['thought'];
    }
    if (_draftConfig['mode'] != null) {
      config['mode'] = _draftConfig['mode'];
    }
    return config.isEmpty ? null : config;
  }

  Future<String?> _askHeldQueueDisposition() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.held.title')),
        content: Text(tr(context, 'chat.held.body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'keepQueueAndSend'),
            child: Text(tr(context, 'chat.held.keep')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'clearQueueAndSend'),
            child: Text(tr(context, 'chat.held.clear')),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ history

  Future<void> _loadOlder() async {
    final state = _state;
    final sessionId = _sessionId;
    if (state == null || sessionId == null || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    // Bottom-anchored viewport: prepending shifts content down, so remember
    // the distance-from-bottom and restore it after the insertion frame —
    // the user keeps reading exactly where they were and can scroll up.
    final pxBefore =
        _scrollController.hasClients ? _scrollController.offset : null;
    final bottomBefore = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : null;
    try {
      final res = await widget.gateway.rowsRange(
        sessionId,
        beforeRowId: state.firstRowId,
        limit: 60,
      );
      List? rows;
      int? firstRowId;
      bool? hasMore;
      String? atLogEpoch;
      if (res is Map) {
        hasMore = res['hasMore'] as bool?;
        atLogEpoch = res['atLogEpoch'] as String?;
        // Web parity: drop the whole result when the epoch moved — the
        // window no longer belongs to this subscription.
        if (!state.rangeEnvelopeMatches(atLogEpoch)) {
          if (mounted) _toast(tr(context, 'chat.loadOlder.stale'));
          return;
        }
        final rowsObj = res['rows'];
        if (rowsObj is Map) {
          rows = rowsObj['window'] as List? ?? rowsObj['rows'] as List?;
          firstRowId = (rowsObj['firstRowId'] as num?)?.toInt();
        } else if (rowsObj is List) {
          rows = rowsObj;
        }
        rows ??= res['items'] as List? ?? res['window'] as List?;
        firstRowId ??= (res['firstRowId'] as num?)?.toInt();
      } else if (res is List) {
        rows = res;
      }
      if (rows != null && rows.isNotEmpty) {
        final older =
            rows.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
              ..sort(
                (a, b) => ((a['rowId'] as num?) ?? 0).compareTo(
                  (b['rowId'] as num?) ?? 0,
                ),
              );
        state
          ..hasMore = hasMore
          ..prependOlderRows(older, firstRowId);
        if (_stickToBottom) {
          _scrollToBottom();
        } else if (pxBefore != null && bottomBefore != null) {
          // Restore the viewport: distance-from-bottom is invariant when
          // content is inserted above the visible range.
          final distBefore = bottomBefore - pxBefore;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scrollController.hasClients) return;
            _scrollController.jumpTo(
              (_scrollController.position.maxScrollExtent - distBefore)
                  .clamp(0.0, _scrollController.position.maxScrollExtent),
            );
          });
        }
      } else if (state.rows.isNotEmpty) {
        state.hasMore = hasMore ?? false;
        if (mounted) _toast(tr(context, 'chat.noOlder'));
      }
    } catch (e) {
      if (mounted) _toast(trP(context, 'chat.loadOlder.failed', ['$e']));
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  // ------------------------------------------------------------ sheets

  Future<void> _showModelSheet() async {
    // Official source for the model list (model-selection getView); falls
    // back to prepareWorkspace options when the desktop rejects it.
    final modelChoices = await widget.gateway.modelSelectionView();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => ModelModeSheet(
        gateway: widget.gateway,
        state: _state,
        prep: _prep,
        sessionId: _sessionId,
        draftConfig: _draftConfig,
        modelChoices: modelChoices,
        onDraftChange: (key, value) {
          setState(() => _draftConfig[key] = value);
        },
      ),
    );
  }

  /// Slash entries = builtin/custom commands from prepareWorkspace plus the
  /// desktop's skills (triggered as `$name` in the composer).
  List<SlashItem> get _slashItems {
    final items = <SlashItem>[];
    for (final c in _prep?.slashCommands ?? const <SlashCommand>[]) {
      items.add(
        SlashItem(
          name: c.name,
          description: c.description,
          insert: '/${c.name} ',
          isSkill: false,
        ),
      );
    }
    for (final s in _skills) {
      items.add(
        SlashItem(
          name: s.name,
          description: s.description ??
              (s.argumentHint != null ? '${s.argumentHint}' : ''),
          insert: '\$${s.name} ',
          isSkill: true,
        ),
      );
    }
    return items;
  }

  /// Dedicated skill picker so skills are one tap away (no `/` guessing).
  void _openSkillsPicker() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SkillsPickerSheet(
        skills: _skills,
        loading: _skillsLoading,
        onSelect: (skill) {
          _inputController.text = '\$${skill.name} ';
          _inputController.selection = TextSelection.collapsed(
            offset: _inputController.text.length,
          );
          Navigator.of(context).pop();
          setState(() => _showSlash = false);
        },
        onRefresh: _loadPrep,
      ),
    );
  }

  void _showUsageSheet() {
    final state = _state;
    if (state == null) return;
    showModalBottomSheet(
      context: context,
      builder: (context) => UsageSheet(state: state),
    );
  }

  Future<void> _showPlansSheet() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final plans = await widget.gateway.plans(sessionId);
      if (!mounted) return;
      final rows = plans is Map && plans['plans'] is List
          ? (plans['plans'] as List).whereType<Map>().toList()
          : <Map>[];
      showModalBottomSheet(
        context: context,
        builder: (context) => PlansSheet(state: _state, planRows: rows),
      );
    } catch (e) {
      _toast(trP(context, 'chat.plans.failed', ['$e']));
    }
  }

  /// "更多" menu actions for the session itself.
  Future<void> _renameSession() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final controller = TextEditingController(text: widget.title);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr(context, 'chat.more.rename')),
        content: TextField(
          controller: controller,
          maxLines: 1,
          decoration: InputDecoration(
            hintText: tr(context, 'chat.more.rename.hint'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'devices.add.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr(context, 'chat.more.rename.save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    await _run(
      tr(context, 'tasks.opFailed'),
      () => widget.gateway.renameTask(sessionId, text),
    );
  }

  void _copySessionId() {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    Clipboard.setData(ClipboardData(text: sessionId));
    _toast(tr(context, 'chat.more.idCopied'));
  }

  void _copyWorkspacePath() {
    final path = widget.gateway.workspacePath;
    if (path == null || path.isEmpty) {
      _toast(tr(context, 'chat.more.noPath'));
      return;
    }
    Clipboard.setData(ClipboardData(text: path));
    _toast(tr(context, 'chat.more.pathCopied'));
  }

  void _copyTaskLink() {
    final sessionId = _sessionId;
    final base = widget.gateway.remoteUrl;
    if (sessionId == null || base == null || base.isEmpty) {
      _toast(tr(context, 'chat.more.noLink'));
      return;
    }
    final uri = Uri.parse(base);
    final link = uri.replace(
      queryParameters: {...uri.queryParameters, 'session': sessionId},
    ).toString();
    Clipboard.setData(ClipboardData(text: link));
    _toast(tr(context, 'chat.more.linkCopied'));
  }

  // ------------------------------------------- drafts, history & export

  /// Per-session composer draft (web composerDraftStore). Draft mode (no
  /// session) is intentionally not persisted.
  Future<void> _saveDraft() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('chat.draft.$sessionId', _inputController.text);
    } catch (_) {}
  }

  Future<void> _restoreDraft(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final draft = prefs.getString('chat.draft.$sessionId');
      if (draft == null || draft.isEmpty || _inputController.text.isNotEmpty) {
        return;
      }
      if (mounted) {
        _inputController.text = draft;
        _inputController.selection = TextSelection.collapsed(
          offset: draft.length,
        );
      }
    } catch (_) {}
  }

  static const int _kInputHistoryLimit = 20;

  Future<void> _recordInputHistory(String text) async {
    final value = text.trim();
    if (value.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('chat.inputHistory');
      final list = raw != null && raw.isNotEmpty
          ? List<String>.from(jsonDecode(raw) as List)
          : <String>[];
      list.remove(value);
      list.insert(0, value);
      while (list.length > _kInputHistoryLimit) {
        list.removeLast();
      }
      await prefs.setString('chat.inputHistory', jsonEncode(list));
    } catch (_) {}
  }

  Future<List<String>> _loadInputHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('chat.inputHistory');
      if (raw == null || raw.isEmpty) return const [];
      final list = List<String>.from(jsonDecode(raw) as List);
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _openInputHistory() async {
    final items = await _loadInputHistory();
    if (!mounted) return;
    if (items.isEmpty) {
      _toast(tr(context, 'chat.history.empty'));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                tr(sheetCtx, 'chat.history.title'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final item in items)
              ListTile(
                dense: true,
                title: Text(
                  item,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: ZInk.solid(sheetCtx),
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _inputController.text = item;
                  _inputController.selection = TextSelection.collapsed(
                    offset: item.length,
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Conversation export (web conversationShareMarkdown, client-side only):
  /// user/assistant turns plus compact tool lines. Remote images degrade to
  /// links so the export stays portable.
  String _buildExportMarkdown() {
    final labels = (
      user: tr(context, 'chat.export.role.user'),
      assistant: tr(context, 'chat.export.role.assistant'),
    );
    final buf = StringBuffer('# ${widget.title}\n');
    for (final row in _state?.rows ?? const <Map<String, dynamic>>[]) {
      switch (row['kind']) {
        case 'userInput':
          final text = '${row['text'] ?? ''}'.trim();
          if (text.isNotEmpty) {
            buf.writeln('\n**${labels.user}**\n\n$text');
          }
        case 'assistantText':
          final text = '${row['text'] ?? ''}'.trim();
          if (text.isNotEmpty) {
            buf.writeln('\n**${labels.assistant}**\n\n$text');
          }
        case 'toolCall':
          final status = '${row['status'] ?? ''}';
          final mark = switch (status) {
            'success' => '✓',
            'error' => '✗',
            _ => '…',
          };
          buf.writeln('\n> 🔧 `${row['toolName'] ?? ''}` $mark');
      }
    }
    return _normalizeExportMarkdown(buf.toString());
  }

  /// Web normalizeConversationShareMarkdown: remote images become plain
  /// links (no tracking pixels in exports).
  static String _normalizeExportMarkdown(String md) => md.replaceAllMapped(
        RegExp(r'!\[([^\]]*)\]\((https?://[^)]+)\)'),
        (m) => '[${m.group(1)}](${m.group(2)})',
      );

  Future<void> _showExportSheet() async {
    final md = _buildExportMarkdown();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  tr(sheetCtx, 'chat.export.title'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: Text(tr(sheetCtx, 'chat.export.copy')),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                Clipboard.setData(ClipboardData(text: md));
                _toast(tr(sheetCtx, 'chat.copied'));
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text(tr(sheetCtx, 'chat.export.save')),
              onTap: () async {
                Navigator.of(sheetCtx).pop();
                await _saveExportFile(md);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Saves via the already-shipped file_picker saveFile (no new plugin —
  /// share_plus has no OpenHarmony implementation and would break that CI).
  Future<void> _saveExportFile(String md) async {
    final safeName = widget.title.isEmpty
        ? 'conversation'
        : widget.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    try {
      final path = await FilePicker.saveFile(
        fileName: '$safeName.md',
        type: FileType.custom,
        allowedExtensions: const ['md'],
        bytes: Uint8List.fromList(utf8.encode(md)),
      );
      if (path != null && mounted) {
        _toast(tr(context, 'chat.export.saved'));
      }
    } catch (e) {
      if (mounted) _toast(trP(context, 'chat.export.failed', ['$e']));
    }
  }

  /// The "更多" dropdown actions (official second header row).
  void _onMoreMenu(String action) {
    final sessionId = _sessionId;
    switch (action) {
      case 'rename':
        _renameSession();
      case 'pin':
        if (sessionId != null) {
          final target = !_pinned;
          _run(
            tr(context, 'tasks.opFailed'),
            () => widget.gateway.setTaskPinned(sessionId, target),
          );
          setState(() => _pinned = target);
        }
      case 'archive':
        if (sessionId != null) {
          _run(
            tr(context, 'tasks.opFailed'),
            () => widget.gateway.setTaskArchived(sessionId, true),
          );
        }
      case 'unread':
        if (sessionId != null) {
          _run(
            tr(context, 'tasks.opFailed'),
            () => widget.gateway.setTaskUnread(sessionId, true),
          );
        }
      case 'copyPath':
        _copyWorkspacePath();
      case 'copyId':
        _copySessionId();
      case 'copyLink':
        _copyTaskLink();
      case 'compact':
        if (sessionId != null) {
          _run(
            tr(context, 'chat.compact.failed'),
            () => widget.gateway.compact(sessionId),
          );
        }
      case 'usage':
        _showUsageSheet();
      case 'plans':
        _showPlansSheet();
      case 'export':
        _showExportSheet();
      case 'deleteSession':
        if (sessionId != null) {
          _deleteSession(sessionId);
        }
    }
  }

  /// Official delete confirmation (confirmDialog.taskDelete*): the session
  /// is removed from the workspace and records cannot be recovered. Pops
  /// the chat page after success.
  Future<void> _deleteSession(String sessionId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogCtx) => AlertDialog(
        title: Text(tr(dialogCtx, 'tasks.action.deleteTitle')),
        content: Text(
          trP(dialogCtx, 'tasks.action.deleteDesc', [
            widget.title.isNotEmpty ? widget.title : sessionId,
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(tr(dialogCtx, 'common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(tr(dialogCtx, 'tasks.action.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      tr(context, 'tasks.opFailed'),
      () => widget.gateway.deleteSession(sessionId),
    );
    if (mounted) Navigator.of(context).maybePop();
  }

  /// Official web order: pin toggle / rename / archive / unread, then the
  /// copy actions; client-only extras (link, compact, usage, plans) trail.
  List<PopupMenuEntry<String>> _moreMenuItems(BuildContext context) => [
        _menuItem(
          'pin',
          Icons.push_pin_outlined,
          _pinned ? 'chat.more.unpin' : 'chat.more.pin',
        ),
        _menuItem('rename', Icons.edit_outlined, 'chat.more.rename'),
        _menuItem('archive', Icons.archive_outlined, 'chat.more.archive'),
        _menuItem(
            'unread', Icons.mark_email_unread_outlined, 'chat.more.unread'),
        const PopupMenuDivider(),
        _menuItem('copyPath', Icons.folder_copy_outlined, 'chat.more.copyPath'),
        _menuItem('copyId', Icons.tag, 'chat.more.copyId'),
        const PopupMenuDivider(),
        _menuItem('copyLink', Icons.link, 'chat.more.copyLink'),
        _menuItem('compact', Icons.compress, 'chat.more.compact'),
        _menuItem('usage', Icons.query_stats_outlined, 'chat.more.usage'),
        _menuItem('plans', Icons.checklist_outlined, 'chat.more.plans'),
        _menuItem('export', Icons.ios_share_outlined, 'chat.more.export'),
        const PopupMenuDivider(),
        _menuItem('deleteSession', Icons.delete_outline, 'tasks.action.delete'),
      ];

  /// Official content column: messages cap at 848px, the composer at 864px,
  /// centered inside the pane. On narrow screens they simply fill.
  static const double _kMessageColumnWidth = 848;
  static const double _kComposerColumnWidth = 864;

  Widget _contentCol(Widget child, {double maxWidth = _kMessageColumnWidth}) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final chat = Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text(tr(context, 'chat.appBar')),
        actions: [
          IconButton(
            icon: const Icon(Icons.search, size: 20),
            tooltip: tr(context, 'chat.search.tooltip'),
            onPressed: _openSearch,
          ),
          if (widget.theme != null)
            IconButton(
              icon: Icon(
                  switch (widget.theme!.mode) {
                    ThemeMode.dark => Icons.dark_mode_outlined,
                    ThemeMode.light => Icons.light_mode_outlined,
                    _ => Icons.brightness_6_outlined,
                  },
                  size: 20),
              tooltip: tr(context, 'settings.theme'),
              onPressed: widget.theme!.cycle,
            ),
        ],
      ),
      body: Column(
        children: [
          // Official second header row: task title + workspace chip + 更多.
          _contentCol(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: ZInk.solid(context),
                      ),
                    ),
                  ),
                  if (widget.workspaceLabel != null &&
                      widget.workspaceLabel!.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: ZInk.tile(context),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: ZInk.hairline(context)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.folder_outlined,
                            size: 13,
                            color: ZInk.muted(context),
                          ),
                          const SizedBox(width: 4),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 96),
                            child: Text(
                              widget.workspaceLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: ZInk.muted(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  PopupMenuButton<String>(
                    tooltip: tr(context, 'chat.more'),
                    onSelected: _onMoreMenu,
                    itemBuilder: _moreMenuItems,
                    position: PopupMenuPosition.under,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tr(context, 'chat.more'),
                            style: const TextStyle(
                              fontSize: 13,
                              color: ZColors.sky500,
                            ),
                          ),
                          const Icon(
                            Icons.keyboard_arrow_down,
                            size: 16,
                            color: ZColors.sky500,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: ChatSearchBar(
                controller: _searchController,
                count: _searchHitRowIds.isEmpty
                    ? (_searchQuery.isEmpty
                        ? ''
                        : tr(context, 'chat.search.none'))
                    : trP(context, 'chat.search.count', [
                        '${_searchCursor + 1}',
                        '${_searchHitRowIds.length}',
                      ]),
                onChanged: _onSearchChanged,
                onSubmitted: _submitSearch,
                onPrev: () => _gotoSearchHit(-1),
                onNext: () => _gotoSearchHit(1),
                onClose: _closeSearch,
              ),
            ),
          if (_sessionId != null)
            AnimatedBuilder(
              animation: widget.gateway,
              builder: (context, _) => QuotaBanner(gateway: widget.gateway),
            ),
          // Official statusPanel inline layout: the workflow/terminal
          // sections sit at the TOP of the conversation (web renders the
          // panel above the timeline), not above the composer.
          if (state != null)
            AnimatedBuilder(
              animation: state,
              builder: (context, _) => _contentCol(
                // Height-capped: an expanded section with many rows must
                // not squeeze/overflow the timeline below.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.45,
                  ),
                  child: SingleChildScrollView(
                    child: StatusPanel(state: state, gateway: widget.gateway),
                  ),
                ),
              ),
            ),
          if (_error != null)
            Material(
              color: ZColors.danger.withValues(alpha: 0.15),
              child: ListTile(
                dense: true,
                title: Text(
                  trP(context, 'chat.subscribe.failed', ['$_error']),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: TextButton(
                  onPressed: _subscribe,
                  child: Text(tr(context, 'tasks.retry')),
                ),
              ),
            ),
          Expanded(
            child: state == null
                ? Center(
                    child: _sessionId == null
                        ? Text(
                            tr(context, 'chat.draftHint'),
                            style: TextStyle(color: ZInk.faint(context)),
                          )
                        : const CircularProgressIndicator(),
                  )
                : !state.ready
                    ? const Center(child: CircularProgressIndicator())
                    : AnimatedBuilder(
                        animation: state,
                        builder: (context, _) {
                          final groups = groupTurnRows(state.rows);
                          final itemCount =
                              groups.length + (state.canLoadOlder ? 1 : 0);
                          if (groups.isEmpty && !state.canLoadOlder) {
                            return Center(
                              child: Text(
                                tr(context, 'chat.empty'),
                                style: TextStyle(color: ZInk.faint(context)),
                              ),
                            );
                          }
                          return _contentCol(
                            Stack(
                              children: [
                                ListView.builder(
                                  controller: _scrollController,
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 8, 16, 8),
                                  itemCount: itemCount,
                                  itemBuilder: (context, index) {
                                    if (state.canLoadOlder && index == 0) {
                                      return Center(
                                        child: TextButton.icon(
                                          onPressed:
                                              _loadingOlder ? null : _loadOlder,
                                          icon: _loadingOlder
                                              ? const SizedBox(
                                                  width: 12,
                                                  height: 12,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 1.5,
                                                  ),
                                                )
                                              : const Icon(Icons.history,
                                                  size: 14),
                                          label: Text(
                                            tr(context, 'chat.loadOlder'),
                                            style:
                                                const TextStyle(fontSize: 12),
                                          ),
                                        ),
                                      );
                                    }
                                    final groupIndex =
                                        index - (state.canLoadOlder ? 1 : 0);
                                    final group = groups[groupIndex];
                                    final previous = groupIndex > 0
                                        ? groups[groupIndex - 1]
                                        : null;
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        if (_timeDividerLabel(
                                                previous, group) !=
                                            null)
                                          TimeDivider(
                                            label: _timeDividerLabel(
                                                previous, group)!,
                                          ),
                                        TurnGroupWidget(
                                          key: group.isEmpty
                                              ? null
                                              : _turnKeyFor(
                                                  _rowIdOf(group.first)),
                                          rows: group,
                                          gateway: widget.gateway,
                                          sessionId: _sessionId ?? '',
                                          onAction: _run,
                                          state: state,
                                        ),
                                      ],
                                    );
                                  },
                                ),
                                if (groups.length >= 4)
                                  Positioned(
                                    right: 0,
                                    top: 0,
                                    bottom: 0,
                                    child: Center(
                                      child: TurnNavigatorRail(
                                        turnCount: groups.length,
                                        activeIndex: _visibleTurn,
                                        onJump: (i) {
                                          if (i < groups.length &&
                                              groups[i].isNotEmpty) {
                                            _jumpToTurnRowId(
                                              _rowIdOf(groups[i].first),
                                            );
                                          }
                                        },
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
          AnimatedBuilder(
            animation: widget.gateway,
            builder: (context, _) => _GatewayBanner(gateway: widget.gateway),
          ),
          if (state != null)
            // Height-capped + reversed scroll: the panels keep their natural
            // height normally, but tall stacks (plan approval + hook review
            // + banners) cap out instead of overflowing the body column on
            // small windows. Not a Flexible — that would claim flex space
            // even when the panels are empty.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.45,
              ),
              child: SingleChildScrollView(
                reverse: true,
                child: AnimatedBuilder(
                  animation: state,
                  builder: (context, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      QueueBar(state: state, gateway: widget.gateway),
                      PendingInteractions(
                        state: state,
                        gateway: widget.gateway,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_showSlash)
            SlashCommandBar(
              query: _inputController.text,
              items: _slashItems,
              onSelect: (item) {
                if (item.name == 'compact') {
                  _inputController.text = '/compact';
                  _send();
                } else {
                  _inputController.text = item.insert;
                  _inputController.selection = TextSelection.collapsed(
                    offset: _inputController.text.length,
                  );
                  setState(() => _showSlash = false);
                }
              },
            ),
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _progress!,
                    style: TextStyle(fontSize: 11, color: ZInk.muted(context)),
                  ),
                ],
              ),
            ),
          if (_pendingFiles.isNotEmpty)
            PendingFilesBar(
              files: _pendingFiles,
              uploadProgress: _uploadProgress,
              onRemove: (i) => setState(() => _pendingFiles.removeAt(i)),
            ),
          if (!widget.readOnly)
          AnimatedBuilder(
            animation: (state == null)
                ? widget.gateway
                : Listenable.merge([state, widget.gateway]),
            builder: (context, _) => _contentCol(
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state == null &&
                      _sessionId == null &&
                      !_sending &&
                      _inputController.text.isEmpty &&
                      _pendingFiles.isEmpty)
                    DraftSuggestedPrompts(
                      onPick: (text) {
                        _inputController.text = text;
                        _inputController.selection = TextSelection.collapsed(
                          offset: text.length,
                        );
                      },
                    ),
                  ChatInputBar(
                    controller: _inputController,
                    sending: _sending,
                    hasAttachments: _pendingFiles.isNotEmpty,
                    isDraft: _sessionId == null,
                    state: state,
                    prep: _prep,
                    draftConfig: _draftConfig,
                    gateway: widget.gateway,
                    sessionId: _sessionId,
                    onSend: _send,
                    onAttach: _pickFiles,
                    onSkills: _openSkillsPicker,
                    onHistory: _openInputHistory,
                    onModelSheet: _showModelSheet,
                    onUsage: _showUsageSheet,
                  ),
                ],
              ),
              maxWidth: _kComposerColumnWidth,
            ),
          ),
        ],
      ),
    );
    return AnimatedBuilder(
      animation: widget.gateway,
      builder: (context, _) => widget.gateway.kicked
          ? Stack(children: [chat, _kickedOverlay(context)])
          : chat,
    );
  }

  Widget _kickedOverlay(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: ZColors.darkBackground.withValues(alpha: 0.92),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.phonelink_erase_outlined,
                  size: 44,
                  color: ZColors.danger,
                ),
                const SizedBox(height: 16),
                Text(
                  tr(context, 'chat.kicked.title'),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  tr(context, 'chat.kicked.body'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: ZInk.faint(context)),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => _run(
                    tr(context, 'tasks.opFailed'),
                    widget.gateway.reconnect,
                  ),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(tr(context, 'chat.kicked.reconnect')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String key) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(tr(context, key)),
        ],
      ),
    );
  }

  /// Centered HH:mm divider between two groups whose timestamps are more
  /// than 10 minutes apart (official timeline separators). Rows without a
  /// recognizable timestamp field produce no divider.
  String? _timeDividerLabel(
    List<Map<String, dynamic>>? previous,
    List<Map<String, dynamic>> group,
  ) {
    final prevAt = rowTimestamp(previous?.first);
    final at = rowTimestamp(group.first);
    if (at == null) return null;
    if (prevAt != null && at - prevAt < 10 * 60 * 1000) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(at).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
  }
}

/// ---------------------------------------------------------------- rows

/// Banner driven by gateway link status: quiet when healthy, "reconnecting"
/// while the relay link is down mid-chat (a send may pause until recovery).
class _GatewayBanner extends StatelessWidget {
  final ChatGateway gateway;

  const _GatewayBanner({required this.gateway});

  @override
  Widget build(BuildContext context) {
    if (gateway.kicked || gateway.status != DeviceStatus.connecting) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: ZColors.warning.withValues(alpha: 0.15),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tr(context, 'chat.reconnecting'),
              style: TextStyle(fontSize: 12, color: ZInk.soft(context)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Provider business-error translation (web `zcode.error.providerBusiness.*`):
/// model-request failures carry a numeric code (1005 免费额度, 1006 登录失效,
/// 3002/429 限流, 3006 模型不在范围, 3007 验证码, 3008-3010 系统繁忙, 2007 上游
/// 不可用). When the failure text mentions one, show the official line
/// instead of the raw transport error.
String? businessErrorCopy(String errorText, String Function() retryLater) {
  final m =
      RegExp(r'\b(1006|1005|3006|3001|3007|3008|3009|3010|3002|2007|429)\b')
          .firstMatch(errorText);
  if (m == null) return null;
  final copy = {
    '1006': '登录状态已失效，请重新登录后再试。',
    '1005': '免费额度已用完，请升级套餐或稍后再试。',
    '3006': '当前模型不在你的套餐范围内，请更换模型。',
    '3001': '请求参数无效，请重试或更换模型。',
    '3007': '触发验证码校验，请在桌面端完成验证后重试。',
    '3008': '系统繁忙，请稍后重试或升级套餐。',
    '3009': '系统繁忙，请稍后重试或升级套餐。',
    '3010': '系统繁忙，请稍后重试或升级套餐。',
    '3002': '请求被限流，请稍后重试。',
    '2007': '上游服务暂不可用，请稍后重试。',
    '429': '请求被限流，请稍后重试。',
  }[m.group(1)];
  if (copy == null) return null;
  return '$copy (${retryLater.call()})';
}
