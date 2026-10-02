// ignore_for_file: deprecated_member_use // ohos fork's Flutter predates RadioGroup; drop when it lands
import 'package:flutter/material.dart';

import '../protocol/channel_client.dart';
import '../state/device_session.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Desktop settings reachable over the remote bridge
/// (setting channel `get` / `update`). Only keys confirmed in the web
/// client source are rendered — mobile-meaningful subset:
/// 交互行为 (zcodeInteractionBehavior) and 任务自动归档
/// (taskAutoArchiveEnabled / taskAutoArchiveOlderThanDays).
class DesktopSettingsPage extends StatefulWidget {
  final DeviceSession session;
  const DesktopSettingsPage({super.key, required this.session});

  @override
  State<DesktopSettingsPage> createState() => _DesktopSettingsPageState();
}

class _DesktopSettingsPageState extends State<DesktopSettingsPage> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<dynamic> _call(String method, [List<Object?> args = const []]) =>
      widget.session.callChannel(Channels.setting, method, args);

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _call('get');
      if (mounted) {
        setState(() {
          _data = res is Map ? res.cast<String, dynamic>() : {};
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _update(Map<String, dynamic> patch) async {
    setState(() => _saving = true);
    try {
      await _call('update', [patch]);
      if (mounted) {
        setState(() {
          _data = {...?_data, ...patch};
          _saving = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(trP(context, 'deskSet.saveFailed', ['$e']))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'deskSet.title')),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Text(trP(context, 'deskSet.loadFailed', [_error!])))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _interactionCard(context),
                    const SizedBox(height: 10),
                    _autoArchiveCard(context),
                  ],
                ),
    );
  }

  /// zcodeInteractionBehavior: queue | guide (⌘/Ctrl+Enter semantics on
  /// web; here the follow-up default when a turn is running).
  Widget _interactionCard(BuildContext context) {
    final value = '${_data?['zcodeInteractionBehavior'] ?? 'queue'}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'deskSet.interaction'),
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(tr(context, 'deskSet.interactionHint'),
                style: TextStyle(fontSize: 11, color: ZInk.faint(context))),
            const SizedBox(height: 8),
            Column(
              children: [
                for (final (v, label, hint) in [
                  (
                    'queue',
                    tr(context, 'deskSet.interactionQueue'),
                    tr(context, 'deskSet.interactionQueueHint'),
                  ),
                  (
                    'guide',
                    tr(context, 'deskSet.interactionGuide'),
                    tr(context, 'deskSet.interactionGuideHint'),
                  ),
                ])
                  RadioListTile<String>(
                    groupValue: value == 'guide' ? 'guide' : 'queue',
                    value: v,
                    onChanged: (sel) {
                      if (sel != null && sel != value) {
                        _update({'zcodeInteractionBehavior': sel});
                      }
                    },
                    title: Text(label, style: const TextStyle(fontSize: 13.5)),
                    subtitle: Text(hint,
                        style:
                            TextStyle(fontSize: 11, color: ZInk.faint(context))),
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _autoArchiveCard(BuildContext context) {
    final enabled = _data?['taskAutoArchiveEnabled'] == true;
    final days = (_data?['taskAutoArchiveOlderThanDays'] as num?)?.toInt() ?? 7;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: enabled,
              onChanged: (v) => _update({'taskAutoArchiveEnabled': v}),
              title: Text(tr(context, 'deskSet.autoArchive'),
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              subtitle: Text(tr(context, 'deskSet.autoArchiveHint'),
                  style: TextStyle(fontSize: 11, color: ZInk.faint(context))),
            ),
            if (enabled)
              Wrap(
                spacing: 8,
                children: [
                  for (final d in const [3, 7, 14, 30])
                    ChoiceChip(
                      label: Text(
                        trP(context, 'deskSet.autoArchiveDays', ['$d']),
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      selected: days == d,
                      onSelected: (_) =>
                          _update({'taskAutoArchiveOlderThanDays': d}),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
