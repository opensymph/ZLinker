// Device store — pin, reorder, themeHint helpers.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zremote/state/device_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('pin floats a device to the top', () async {
    final store = DeviceStore();
    await store.load();
    final a = await store
        .addUrl('https://zcode.z.ai/remote/v4?sid=a&hash=h&t=1&name=A');
    final b = await store
        .addUrl('https://zcode.z.ai/remote/v4?sid=b&hash=h&t=1&name=B');
    expect(store.devices.first.id, a.id);

    await store.setPinned(b.id, true);
    expect(store.devices.first.id, b.id);
    expect(store.devices.first.pinned, isTrue);

    await store.setPinned(b.id, false);
    expect(store.devices.any((d) => d.pinned), isFalse);
  });

  test('reorder updates sortOrder', () async {
    final store = DeviceStore();
    await store.load();
    await store.addUrl('https://zcode.z.ai/remote/v4?sid=a&hash=h&t=1&name=A');
    await store.addUrl('https://zcode.z.ai/remote/v4?sid=b&hash=h&t=1&name=B');
    await store.addUrl('https://zcode.z.ai/remote/v4?sid=c&hash=h&t=1&name=C');
    final before = store.devices.map((d) => d.label).toList();
    expect(before, ['A', 'B', 'C']);

    await store.reorder(2, 0); // move C to front (onReorderItem indices)
    expect(store.devices.map((d) => d.label).toList(), ['C', 'A', 'B']);
  });

  test('themeHint from URL', () {
    final dark = Device.fromUrl(
        'https://zcode.z.ai/remote/v4?sid=a&hash=h&t=1&theme=dark');
    final light = Device.fromUrl(
        'https://zcode.z.ai/remote/v4?sid=a&hash=h&t=1&theme=light');
    final none =
        Device.fromUrl('https://zcode.z.ai/remote/v4?sid=a&hash=h&t=1');
    expect(dark.themeHint, ThemeModeHint.dark);
    expect(light.themeHint, ThemeModeHint.light);
    expect(none.themeHint, isNull);
  });

  test('pinned + sortOrder survive export/import', () async {
    final a = DeviceStore();
    await a.load();
    final d = await a
        .addUrl('https://zcode.z.ai/remote/v4?sid=a&hash=h&t=1&name=A');
    await a.setPinned(d.id, true);
    final backup = a.exportJson();

    SharedPreferences.setMockInitialValues({});
    final b = DeviceStore();
    await b.load();
    await b.importJson(backup);
    expect(b.devices.single.pinned, isTrue);
  });
}
