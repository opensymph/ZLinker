import 'package:flutter/material.dart';

import '../protocol/conversation.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// Select-style form field for `prepareWorkspace` config options (model,
/// thought level …). The desktop forms pick from the device's available
/// options instead of free-typing, so the client forms do the same: tapping
/// the field opens a sheet with one tile per option (name + provider
/// subtitle), the current value highlighted — the `_ModelModeSheet` pattern.
///
/// [value] is the option's composite `value` string (e.g.
/// `builtin/glm-5.2`); `null` means the "default" choice ([noneLabel]).
class ModelOptionField extends StatefulWidget {
  final Future<WorkspacePrep> Function()? loadOptions;
  final String optionId;
  final String labelText;
  final String? noneLabel;
  final String? value;
  final ValueChanged<String?> onChanged;

  /// Direct option list (skips prepareWorkspace): e.g. the off-peak
  /// availability payload's `allowedModels` (plain model names).
  final List<String>? directValues;

  /// Rich direct options (name + subtitle per value) — wins over
  /// [directValues]: e.g. the model-selection view's provider/model pairs.
  final List<({String value, String name, String? subtitle})>? directOptions;

  /// Desktop off-peak behavior: no "unspecified" row — the field defaults
  /// to the first option instead.
  final bool defaultToFirst;

  const ModelOptionField({
    super.key,
    required this.loadOptions,
    required this.optionId,
    required this.labelText,
    required this.noneLabel,
    required this.value,
    required this.onChanged,
    this.directValues,
    this.directOptions,
    this.defaultToFirst = false,
  });

  @override
  State<ModelOptionField> createState() => _ModelOptionFieldState();
}

class _ModelOptionFieldState extends State<ModelOptionField> {
  WorkspacePrep? _prep;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Prefetch once so the field can render the option's display name
    // (not the raw composite value) for pre-filled edits.
    _load();
  }

  Future<void> _load() {
    if (widget.directOptions != null ||
        widget.directValues != null ||
        widget.loadOptions == null) {
      return Future.value();
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    return widget.loadOptions!().then((prep) {
      if (mounted) setState(() => _prep = prep);
    }).catchError((e) {
      if (mounted) setState(() => _error = '$e');
    }).whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  ConfigOption? get _option => _prep?.option(widget.optionId);

  /// Display-shape options: rich direct options win, then plain direct
  /// values (no provider subtitle), else the config option's values.
  List<({String value, String name, String? subtitle})> get _options {
    final rich = widget.directOptions;
    if (rich != null) return rich;
    final direct = widget.directValues;
    if (direct != null) {
      return [for (final v in direct) (value: v, name: v, subtitle: null)];
    }
    return [
      for (final v in _option?.options ?? const <ConfigOptionValue>[])
        (
          value: v.value,
          name: v.name,
          subtitle: v.modelProviderName ?? v.description
        ),
    ];
  }

  /// Effective selection: explicit value, else the first option when the
  /// field defaults to first (desktop off-peak), else null (= 默认).
  String? get _effectiveValue {
    final v = widget.value;
    if (v != null && v.isNotEmpty) return v;
    if (widget.defaultToFirst && _options.isNotEmpty) {
      return _options.first.value;
    }
    return null;
  }

  String? get _displayName {
    final value = _effectiveValue;
    if (value == null || value.isEmpty) return null;
    for (final v in _options) {
      if (v.value == value) return v.name;
    }
    return value; // unknown/offline: show the stored id as-is
  }

  Future<void> _openSheet() async {
    if (_prep == null && widget.loadOptions != null && _error != null) {
      await _load();
    }
    if (!mounted) return;
    final options = _options;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(widget.labelText,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else ...[
                if (widget.noneLabel != null)
                  _optionTile(sheetCtx,
                      value: null, name: widget.noneLabel!, subtitle: null),
                if (options.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: Text(
                        _error ?? tr(sheetCtx, 'form.options.unavailable'),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: ZInk.faint(sheetCtx)),
                      ),
                    ),
                  )
                else
                  for (final v in options)
                    _optionTile(sheetCtx,
                        value: v.value, name: v.name, subtitle: v.subtitle),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _optionTile(BuildContext sheetCtx,
      {required String? value, required String name, String? subtitle}) {
    final selected = _effectiveValue == value;
    return ListTile(
      dense: true,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        size: 18,
        color: selected ? ZColors.sky500 : ZInk.ghost(sheetCtx),
      ),
      title: Text(name,
          style: TextStyle(fontSize: 13, color: ZInk.solid(sheetCtx))),
      subtitle: subtitle != null && subtitle.isNotEmpty
          ? Text(subtitle,
              style:
                  TextStyle(fontSize: 11, color: ZInk.faint(sheetCtx)))
          : null,
      onTap: () {
        Navigator.of(sheetCtx).pop();
        widget.onChanged(value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = _displayName;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _openSheet,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: widget.labelText,
          suffixIcon: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.arrow_drop_down, size: 20),
        ),
        child: Text(
          name ?? widget.noneLabel ?? '—',
          style: TextStyle(
              fontSize: 13,
              color: name == null ? ZInk.ghost(context) : ZInk.soft(context)),
        ),
      ),
    );
  }
}
