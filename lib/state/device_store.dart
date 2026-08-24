import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/connection_params.dart';
import '../protocol/id.dart';

class Device {
  final String id;
  String label;
  final String url;
  final int addedAt;
  int? lastUsedAt;

  /// Times the device was opened (WebView or native actions). Purely local
  /// usage stats; absent in old backups and defaults to 0.
  int useCount;

  /// User-pinned devices float to the top of the list.
  bool pinned;

  /// Explicit order among siblings (lower = higher). Assigned on add /
  /// reorder; absent in old backups and back-filled from list index.
  int sortOrder;

  Device({
    required this.id,
    required this.label,
    required this.url,
    required this.addedAt,
    this.lastUsedAt,
    this.useCount = 0,
    this.pinned = false,
    this.sortOrder = 0,
  });

  factory Device.fromUrl(String url, {String? label, int sortOrder = 0}) {
    final params = RemoteConnectionParams.parse(url);
    return Device(
      id: generateUuid(),
      label: (label != null && label.trim().isNotEmpty)
          ? label.trim()
          : (params?.deviceName ??
              params?.source.host ??
              '未命名设备'),
      url: url.trim(),
      addedAt: DateTime.now().millisecondsSinceEpoch,
      sortOrder: sortOrder,
    );
  }

  RemoteConnectionParams? get params => RemoteConnectionParams.parse(url);

  /// Prefer the URL's `theme=dark|light` when present.
  ThemeModeHint? get themeHint {
    switch (params?.theme?.toLowerCase()) {
      case 'dark':
        return ThemeModeHint.dark;
      case 'light':
        return ThemeModeHint.light;
      default:
        return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'url': url,
        'addedAt': addedAt,
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt,
        if (useCount > 0) 'useCount': useCount,
        if (pinned) 'pinned': true,
        'sortOrder': sortOrder,
      };

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'] as String? ?? generateUuid(),
        label: j['label'] as String? ?? '未命名设备',
        url: j['url'] as String? ?? '',
        addedAt: j['addedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        lastUsedAt: j['lastUsedAt'] as int?,
        useCount: j['useCount'] as int? ?? 0,
        pinned: j['pinned'] == true,
        sortOrder: j['sortOrder'] as int? ?? 0,
      );
}

/// Lightweight theme hint from a device URL (avoids importing Material here).
enum ThemeModeHint { dark, light }

class DeviceStore extends ChangeNotifier {
  static const _key = 'zremote_devices_v1';
  final List<Device> _devices = [];
  bool _loaded = false;

  /// Devices sorted for display: pinned first, then [Device.sortOrder].
  List<Device> get devices {
    final list = List<Device>.from(_devices);
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final o = a.sortOrder.compareTo(b.sortOrder);
      if (o != 0) return o;
      return a.addedAt.compareTo(b.addedAt);
    });
    return List.unmodifiable(list);
  }

  bool get loaded => _loaded;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _devices
          ..clear()
          ..addAll(list
              .whereType<Map>()
              .map((e) => Device.fromJson(Map<String, dynamic>.from(e)))
              .where((d) => d.url.isNotEmpty));
        _backfillSortOrders();
      } catch (_) {
        // Corrupt storage should not crash the app; start empty.
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// Old backups lack sortOrder — assign contiguous indices once.
  void _backfillSortOrders() {
    var needs = false;
    for (var i = 0; i < _devices.length; i++) {
      if (_devices[i].sortOrder != i &&
          _devices.every((d) => d.sortOrder == 0)) {
        needs = true;
        break;
      }
    }
    if (!needs && _devices.length > 1) {
      final allZero = _devices.every((d) => d.sortOrder == 0);
      if (allZero) needs = true;
    }
    if (!needs) return;
    for (var i = 0; i < _devices.length; i++) {
      _devices[i].sortOrder = i;
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(_devices.map((d) => d.toJson()).toList()));
  }

  /// Adds a device from a pasted/scanned URL. Returns the new device, or the
  /// existing one if the URL was already stored (dedupe).
  Future<Device> addUrl(String url, {String? label}) async {
    final trimmed = url.trim();
    final existing =
        _devices.where((d) => d.url == trimmed).firstOrNull;
    if (existing != null) return existing;
    final maxOrder = _devices.isEmpty
        ? -1
        : _devices.map((d) => d.sortOrder).reduce((a, b) => a > b ? a : b);
    final device = Device.fromUrl(trimmed, label: label, sortOrder: maxOrder + 1);
    _devices.add(device);
    notifyListeners();
    await _save();
    return device;
  }

  Future<void> remove(String id) async {
    _devices.removeWhere((d) => d.id == id);
    notifyListeners();
    await _save();
  }

  Future<void> rename(String id, String label) async {
    final d = _devices.firstWhere((e) => e.id == id, orElse: () => throw StateError('not found'));
    d.label = label.trim().isEmpty ? d.label : label.trim();
    notifyListeners();
    await _save();
  }

  Future<void> setPinned(String id, bool pinned) async {
    final d = _devices.where((e) => e.id == id).firstOrNull;
    if (d == null || d.pinned == pinned) return;
    d.pinned = pinned;
    notifyListeners();
    await _save();
  }

  /// Reorders within the currently displayed list. [oldIndex]/[newIndex]
  /// are indices into [devices] where [newIndex] is the destination after
  /// the item at [oldIndex] has been removed (ReorderableListView
  /// `onReorderItem` convention). Pin state is unchanged.
  Future<void> reorder(int oldIndex, int newIndex) async {
    final visible = devices.toList();
    if (oldIndex < 0 || oldIndex >= visible.length) return;
    if (newIndex < 0 || newIndex >= visible.length) return;
    if (oldIndex == newIndex) return;
    final item = visible.removeAt(oldIndex);
    visible.insert(newIndex, item);
    for (var i = 0; i < visible.length; i++) {
      visible[i].sortOrder = i;
    }
    notifyListeners();
    await _save();
  }

  Future<void> touch(String id) async {
    final d = _devices.where((d) => d.id == id).firstOrNull;
    if (d == null) return;
    d.lastUsedAt = DateTime.now().millisecondsSinceEpoch;
    d.useCount += 1;
    notifyListeners();
    await _save();
  }

  /// Backup/export envelope.
  String exportJson() => jsonEncode({
        'app': 'zremote',
        'format': 'devices',
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'devices': _devices.map((d) => d.toJson()).toList(),
      });

  /// Imports devices from [exportJson] output. Skips duplicates and empty
  /// URLs. Returns the number of devices added.
  Future<int> importJson(String raw) async {
    final data = jsonDecode(raw);
    final list = (data is Map<String, dynamic> ? data['devices'] : data)
        as List<dynamic>;
    var added = 0;
    for (final item in list.whereType<Map>()) {
      final map = Map<String, dynamic>.from(item);
      final url = (map['url'] as String? ?? '').trim();
      if (url.isEmpty) continue;
      if (_devices.any((d) => d.url == url)) continue;
      _devices.add(Device.fromJson(map));
      added++;
    }
    if (added > 0) {
      _backfillSortOrders();
      notifyListeners();
      await _save();
    }
    return added;
  }
}
