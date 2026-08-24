import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

import 'notifications/notification_service.dart';
import 'state/device_session.dart';
import 'state/device_store.dart';
import 'state/notification_hub.dart';
import 'state/scheduled_store.dart';
import 'ui/chat/chat_page.dart';
import 'ui/devices_page.dart';
import 'ui/remote_page.dart';
import 'ui/task_list_page.dart';
import 'ui/theme.dart';
import 'ui/ui_settings.dart';
import 'widgets/home_widget_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ZRemoteApp());
}

class ZRemoteApp extends StatefulWidget {
  const ZRemoteApp({super.key});

  @override
  State<ZRemoteApp> createState() => _ZRemoteAppState();
}

class _ZRemoteAppState extends State<ZRemoteApp> {
  final DeviceStore _store = DeviceStore();
  final ThemeController _theme = ThemeController();
  final UiSettings _ui = UiSettings();
  final ScheduledStore _scheduled = ScheduledStore();
  final NotificationService _notifications = NotificationService();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final DeviceSessionHub _hub = DeviceSessionHub(
    nativeListEnabled: () => _ui.nativeListEnabled,
  );
  late final MessageScheduler _scheduler = MessageScheduler(
    store: _scheduled,
    devices: _store,
    hub: _hub,
  );
  late final NotificationHub _notifyHub = NotificationHub(
    service: _notifications,
    ui: _ui,
    deviceLabelOf: (id) =>
        _store.devices.where((d) => d.id == id).firstOrNull?.label ?? id,
  );
  StreamSubscription? _widgetClickSub;
  StreamSubscription? _appLinkSub;
  final _appLinks = AppLinks();

  @override
  void initState() {
    super.initState();
    _theme.load();
    _ui.load();
    _scheduled.load();
    unawaited(_store.load().then((_) {
      HomeWidgetBridge.syncDevices(_store.devices);
    }));
    // Fire due scheduled messages while the app is alive.
    _scheduler.start();
    // Local notifications: task events ride the sessions stream; off-peak
    // and automation results poll. Tapping deep-links to the conversation.
    _notifications.onTap = _handleNotificationTap;
    unawaited(_notifications.init());
    _hub.addListener(_syncNotifyHub);
    _syncNotifyHub();
    _notifyHub.start();
    unawaited(HomeWidgetBridge.init());
    _listenHomeWidget();
    _listenAppLinks();
  }

  void _listenAppLinks() {
    _appLinks.getInitialLink().then(_openFromWidgetUri);
    _appLinkSub = _appLinks.uriLinkStream.listen(_openFromWidgetUri);
  }

  void _listenHomeWidget() {
    HomeWidget.initiallyLaunchedFromHomeWidget().then((uri) {
      if (uri != null) _openFromWidgetUri(uri);
    });
    _widgetClickSub = HomeWidget.widgetClicked.listen(_openFromWidgetUri);
  }

  Future<void> _openFromWidgetUri(Uri? uri) async {
    if (uri == null) return;
    // zremote://device/<id>  or  /device/<id>
    final id = uri.host == 'device'
        ? (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null)
        : (uri.pathSegments.length >= 2 && uri.pathSegments.first == 'device'
            ? uri.pathSegments[1]
            : null);
    if (id == null || id.isEmpty) return;
    if (!_store.loaded) await _store.load();
    final device = _store.devices.where((d) => d.id == id).firstOrNull;
    if (device == null) return;
    await _store.touch(device.id);
    final session = _hub.ensure(device);
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    if (_ui.nativeListEnabled && session != null) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TaskListPage(
          store: _store,
          hub: _hub,
          device: device,
          theme: _theme,
        ),
      ));
      return;
    }
    await _hub.suspend(device.id);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RemotePage(device: device),
    ));
    _hub.scheduleResume(device);
  }

  void _syncNotifyHub() {
    if (mounted) _notifyHub.syncWith(_hub.activeSessions);
  }

  /// Notification tap → the producing conversation: native chat page when
  /// the protocol link is up (no WebView suspend), WebView deep link as
  /// fallback for devices without a native session.
  Future<void> _handleNotificationTap(Map<String, dynamic> payload) async {
    final deviceId = payload['deviceId'] as String?;
    if (deviceId == null) return;
    final device = _store.devices.where((d) => d.id == deviceId).firstOrNull;
    if (device == null) return;
    final sessionId = payload['sessionId'] as String?;
    final title = payload['title'] as String?;
    await _store.touch(device.id);
    final session = _hub.ensure(device);
    if (!mounted) return;
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    if (session != null) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatPage(
          gateway: session,
          sessionId: sessionId,
          title: title ?? device.label,
          theme: _theme,
        ),
      ));
      return;
    }
    await _hub.suspend(device.id);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RemotePage(
        device: device,
        targetSessionId: sessionId,
        targetTitle: title,
      ),
    ));
    _hub.scheduleResume(device);
  }

  @override
  void dispose() {
    _widgetClickSub?.cancel();
    _appLinkSub?.cancel();
    _notifyHub.dispose();
    _hub.removeListener(_syncNotifyHub);
    _scheduler.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_theme, _ui]),
      builder: (context, _) {
        return MaterialApp(
          navigatorKey: _navigatorKey,
          title: 'ZRemote',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: _theme.mode,
          // Wraps the whole navigator so dialogs/overlays see tr() too.
          builder: (context, child) =>
              UiSettingsProvider(settings: _ui, child: child!),
          home: DevicesPage(
            store: _store,
            theme: _theme,
            ui: _ui,
            hub: _hub,
            scheduled: _scheduled,
          ),
        );
      },
    );
  }
}
