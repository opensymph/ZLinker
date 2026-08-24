import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../protocol/connection_params.dart';
import '../state/device_session.dart';
import '../state/device_store.dart';
import '../state/scheduled_store.dart';
import '../widgets/home_widget_bridge.dart';
import 'qr_scan_page.dart';
import 'remote_page.dart';
import 'scheduled_page.dart';
import 'settings_page.dart';
import 'task_list_page.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Home: the device list with live native status. Tap a card to open the
/// native task list (or WebView fallback), long-term management via the
/// overflow menu. Supports clipboard offer-to-add, drag-reorder and pin.
class DevicesPage extends StatefulWidget {
  final DeviceStore store;
  final ThemeController theme;
  final UiSettings ui;
  final DeviceSessionHub hub;
  final ScheduledStore scheduled;
  const DevicesPage({
    super.key,
    required this.store,
    required this.theme,
    required this.ui,
    required this.hub,
    required this.scheduled,
  });

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage>
    with WidgetsBindingObserver {
  /// Last clipboard URL we already offered (or the user dismissed) so we
  /// don't spam the snackbar on every resume.
  String? _clipboardHandled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.store.load().then((_) {
      _syncConnections();
      _syncHomeWidget();
      _checkClipboard();
    });
    widget.store.addListener(_onStoreChanged);
    widget.ui.addListener(_syncConnections);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_onStoreChanged);
    widget.ui.removeListener(_syncConnections);
    super.dispose();
  }

  void _onStoreChanged() {
    _syncConnections();
    _syncHomeWidget();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
      _syncHomeWidget();
    }
  }

  void _syncHomeWidget() {
    HomeWidgetBridge.syncDevices(widget.store.devices);
  }

  /// Keeps native connections in step with the device list and the
  /// native-list switch (see [DeviceSessionHub.syncWith]).
  void _syncConnections() {
    if (!widget.store.loaded || !mounted) return;
    widget.hub.syncWith(widget.store.devices);
  }

  /// On resume / first load: if the clipboard holds a remote URL that is
  /// not already saved, offer to add it.
  Future<void> _checkClipboard() async {
    if (!mounted) return;
    // Widget tests have no clipboard channel — skip to avoid pending timers.
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    if (bindingName.contains('TestWidgetsFlutterBinding') ||
        bindingName.contains('AutomatedTest')) {
      return;
    }
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty || text == _clipboardHandled) return;
      if (RemoteConnectionParams.parse(text) == null) return;
      if (widget.store.devices.any((d) => d.url == text)) {
        _clipboardHandled = text;
        return;
      }
      _clipboardHandled = text;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(tr(context, 'devices.clipboard.offer')),
          action: SnackBarAction(
            label: tr(context, 'devices.clipboard.add'),
            onPressed: () async {
              await widget.store.addUrl(text);
            },
          ),
        ),
      );
    } catch (_) {
      // Clipboard access can fail on some platforms / permissions / tests.
    }
  }

  /// Card tap: native task list when the protocol link is healthy, the
  /// WebView remote page otherwise.
  Future<void> _open(Device device) async {
    final session = widget.hub.sessionOf(device.id);
    if (widget.ui.nativeListEnabled &&
        session != null &&
        session.status != DeviceStatus.error) {
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _deviceThemeWrap(
          device,
          TaskListPage(
            store: widget.store,
            hub: widget.hub,
            device: device,
            theme: widget.theme,
          ),
        ),
      ));
      return;
    }
    await _openRemote(device);
  }

  /// Applies the device URL's `theme=dark|light` for the opened route.
  Widget _deviceThemeWrap(Device device, Widget child) {
    final hint = device.themeHint;
    if (hint == null) return child;
    final data = hint == ThemeModeHint.dark
        ? buildDarkTheme()
        : buildLightTheme();
    return Theme(data: data, child: child);
  }

  /// Opens the in-app WebView remote page. The native connection is
  /// suspended first (one terminal per device) and resumes ~1s after the
  /// page pops. Injects `theme=` from the URL when present.
  Future<void> _openRemote(Device device) async {
    await widget.store.touch(device.id);
    await widget.hub.suspend(device.id);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _deviceThemeWrap(
        device,
        RemotePage(device: device),
      ),
    ));
    widget.hub.scheduleResume(device);
  }

  Future<void> _addByUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.add.pasteTitle')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 2,
          keyboardType: TextInputType.url,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: tr(context, 'devices.add.pasteHint2'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: Text(tr(context, 'devices.add.confirm')),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty) return;
    final device = await widget.store.addUrl(url);
    if (!mounted) return;
    if (device.params == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'devices.add.savedUnparsed'))),
      );
    }
  }

  Future<void> _addByScan() async {
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );
    if (url == null || url.trim().isEmpty) return;
    final device = await widget.store.addUrl(url);
    if (!mounted) return;
    if (device.params == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'devices.add.savedUnparsed'))),
      );
    }
  }

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: Text(tr(context, 'devices.add.scan')),
              subtitle: Text(tr(context, 'devices.add.scanHint')),
              onTap: () {
                Navigator.pop(c);
                _addByScan();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(tr(context, 'devices.add.paste')),
              subtitle: Text(tr(context, 'devices.add.pasteHint')),
              onTap: () {
                Navigator.pop(c);
                _addByUrl();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(Device device) async {
    final controller = TextEditingController(text: device.label);
    final label = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.rename.title')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr(context, 'devices.rename.hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, controller.text),
              child: Text(tr(context, 'devices.rename.save'))),
        ],
      ),
    );
    if (label != null) await widget.store.rename(device.id, label);
  }

  Future<void> _delete(Device device) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.delete.title')),
        content:
            Text(trP(context, 'devices.delete.body', [device.label])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(c).colorScheme.error,
                foregroundColor: Theme.of(c).colorScheme.onError),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr(context, 'devices.delete.confirm')),
          ),
        ],
      ),
    );
    if (confirm == true) await widget.store.remove(device.id);
  }

  Future<void> _copyUrl(Device device) async {
    await Clipboard.setData(ClipboardData(text: device.url));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(context, 'devices.copy.done'))));
  }

  Future<void> _openInBrowser(Device device) async {
    await launchUrl(Uri.parse(device.url),
        mode: LaunchMode.externalApplication);
  }

  void _showExport() async {
    await Clipboard.setData(ClipboardData(text: widget.store.exportJson()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr(context, 'devices.export.done'))),
    );
  }

  void _showScheduled() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ScheduledPage(
        devices: widget.store,
        hub: widget.hub,
        store: widget.scheduled,
      ),
    ));
  }

  Future<void> _showImport() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr(context, 'devices.import.title')),
        content: TextField(
          controller: controller,
          maxLines: 5,
          minLines: 3,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: InputDecoration(hintText: tr(context, 'devices.import.hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr(context, 'devices.add.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, controller.text),
              child: Text(tr(context, 'devices.import.confirm'))),
        ],
      ),
    );
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final n = await widget.store.importJson(raw);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trP(context, 'devices.import.done', ['$n']))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'devices.import.invalid'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'app.title')),
        actions: [
          IconButton(
            tooltip: tr(context, 'settings.title'),
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SettingsPage(
                store: widget.store,
                theme: widget.theme,
                ui: widget.ui,
              ),
            )),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'export') _showExport();
              if (v == 'import') _showImport();
              if (v == 'sched') _showScheduled();
            },
            itemBuilder: (c) => [
              PopupMenuItem(
                  value: 'export', child: Text(tr(context, 'devices.menu.export'))),
              PopupMenuItem(
                  value: 'import', child: Text(tr(context, 'devices.menu.import'))),
              PopupMenuItem(
                  value: 'sched', child: Text(tr(context, 'sched.menu'))),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddSheet,
        icon: const Icon(Icons.add),
        label: Text(tr(context, 'devices.add')),
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([widget.store, widget.hub, widget.ui]),
        builder: (context, _) {
          final devices = widget.store.devices;
          if (!widget.store.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (devices.isEmpty) return _emptyState(context);
          return RefreshIndicator(
            onRefresh: () async => _syncConnections(),
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              itemCount: devices.length,
              proxyDecorator: (child, index, animation) {
                return AnimatedBuilder(
                  animation: animation,
                  builder: (context, _) => Material(
                    elevation: 2 + animation.value * 4,
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: child,
                  ),
                );
              },
              onReorderItem: (oldIndex, newIndex) {
                widget.store.reorder(oldIndex, newIndex);
              },
              itemBuilder: (context, i) {
                final d = devices[i];
                return Padding(
                  key: ValueKey(d.id),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _deviceCard(d),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: ZColors.sky500.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.devices, size: 36, color: ZColors.sky500),
            ),
            const SizedBox(height: 20),
            Text(tr(context, 'devices.empty.title'),
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: ZInk.solid(context))),
            const SizedBox(height: 8),
            Text(
              tr(context, 'devices.empty.body'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: ZInk.faint(context)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceCard(Device device) {
    final host = device.params?.source.host ?? '';
    final session = widget.hub.sessionOf(device.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(device),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: ListTile(
            leading: _deviceLeading(context, session, device.pinned),
            title: Row(
              children: [
                if (device.pinned) ...[
                  Icon(Icons.push_pin, size: 14, color: ZInk.muted(context)),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    device.label,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _statusLine(context, session),
                  if (host.isNotEmpty)
                    Text(host,
                        style: TextStyle(
                            fontSize: 11, color: ZInk.faint(context))),
                  Text(
                    device.lastUsedAt != null
                        ? trP(context, 'devices.lastUsed', [
                            relativeTime(context, device.lastUsedAt!)
                          ])
                        : tr(context, 'devices.neverUsed'),
                    style:
                        TextStyle(fontSize: 11, color: ZInk.ghost(context)),
                  ),
                ],
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ReorderableDragStartListener(
                  index: widget.store.devices.indexWhere((d) => d.id == device.id),
                  child: Icon(Icons.drag_handle, color: ZInk.ghost(context)),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'pin':
                        widget.store.setPinned(device.id, !device.pinned);
                      case 'rename':
                        _rename(device);
                      case 'web':
                        _openRemote(device);
                      case 'browser':
                        _openInBrowser(device);
                      case 'copy':
                        _copyUrl(device);
                      case 'delete':
                        _delete(device);
                    }
                  },
                  itemBuilder: (c) => [
                    PopupMenuItem(
                        value: 'pin',
                        child: Text(tr(
                            context,
                            device.pinned
                                ? 'devices.menu.unpin'
                                : 'devices.menu.pin'))),
                    PopupMenuItem(
                        value: 'rename',
                        child: Text(tr(context, 'devices.menu.rename'))),
                    PopupMenuItem(
                        value: 'web', child: Text(tr(context, 'devices.menu.web'))),
                    PopupMenuItem(
                        value: 'browser',
                        child: Text(tr(context, 'devices.menu.browser'))),
                    PopupMenuItem(
                        value: 'copy',
                        child: Text(tr(context, 'devices.menu.copy'))),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(tr(context, 'devices.menu.delete'),
                          style: TextStyle(
                              color: Theme.of(c).colorScheme.error)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Device avatar with a live status dot and a running-task badge.
  Widget _deviceLeading(
      BuildContext context, DeviceSession? session, bool pinned) {
    final running = session?.runningTaskCount ?? 0;
    final dotColor = switch (session?.status) {
      DeviceStatus.connected => ZColors.success,
      DeviceStatus.connecting => ZColors.sky500,
      DeviceStatus.error => ZColors.danger,
      _ => ZColors.neutral400,
    };
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: ZColors.sky500.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            pinned ? Icons.push_pin_outlined : Icons.desktop_windows_outlined,
            size: 22,
            color: ZColors.sky500,
          ),
        ),
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              border: Border.all(
                  color: Theme.of(context).colorScheme.surface, width: 2.5),
            ),
          ),
        ),
        if (running > 0)
          Positioned(
            right: -8,
            top: -8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: ZColors.sky500,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: Theme.of(context).colorScheme.surface, width: 2),
              ),
              child: Text(
                running > 9 ? '9+' : '$running',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _statusLine(BuildContext context, DeviceSession? session) {
    final (text, color) = switch (session?.status) {
      DeviceStatus.connected => session != null && session.runningTaskCount > 0
          ? (trP(context, 'status.tasksRunning',
                ['${session.runningTaskCount}']),
              ZColors.success)
          : (tr(context, 'status.online'), ZColors.success),
      DeviceStatus.connecting =>
        (tr(context, 'status.connecting'), ZColors.sky500),
      DeviceStatus.error => session?.kicked == true
          ? (tr(context, 'status.kicked'), ZColors.danger)
          : (tr(context, 'status.error'), ZColors.danger),
      _ => (tr(context, 'status.offline'), ZInk.ghost(context)),
    };
    return Text(text, style: TextStyle(fontSize: 12, color: color));
  }
}
