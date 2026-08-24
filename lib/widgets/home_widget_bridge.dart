import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';

import '../state/device_store.dart';

/// Bridges the device list to the Android home-screen widget.
///
/// Writes a compact JSON payload the App Widget provider reads, then
/// requests a redraw. No-ops on iOS / desktop / when the plugin is absent.
class HomeWidgetBridge {
  static const androidName = 'ZRemoteWidgetProvider';
  static const dataKey = 'devices_json';

  static Future<void> syncDevices(List<Device> devices) async {
    if (kIsWeb) return;
    // Skip when no platform channel (widget tests / pure Dart).
    if (WidgetsBinding.instance.runtimeType
        .toString()
        .contains('TestWidgetsFlutterBinding')) {
      return;
    }
    try {
      final payload = jsonEncode([
        for (final d in devices.take(5))
          {
            'id': d.id,
            'label': d.label,
            'pinned': d.pinned,
          },
      ]);
      await HomeWidget.saveWidgetData<String>(dataKey, payload)
          .timeout(const Duration(milliseconds: 500));
      await HomeWidget.updateWidget(
        name: androidName,
        androidName: androidName,
      ).timeout(const Duration(milliseconds: 500));
    } catch (_) {
      // Plugin unavailable in tests / unsupported platforms.
    }
  }

  /// Register once from [main] so widget taps deep-link into the app.
  static Future<void> init() async {
    if (kIsWeb) return;
    if (WidgetsBinding.instance.runtimeType
        .toString()
        .contains('TestWidgetsFlutterBinding')) {
      return;
    }
    try {
      await HomeWidget.setAppGroupId('group.org.songsong.zremote')
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}
  }
}
