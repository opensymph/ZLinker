import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/device_store.dart';
import 'theme.dart';
import 'ui_settings.dart';

/// DOM contract for the injected session deep-link, verified against the
/// official ZCode web remote (2026-08). Keep in one place so a web client
/// update only touches these selectors:
/// - task list item: `li[data-testid]` whose testid contains the session
///   id, or any `[data-task-item-key]` containing it;
/// - first-screen task picker: clickable `button` whose text contains the
///   task title (a "command palette" style picker auto-opens);
/// - current task marker: `data-mobile-active-task="true"`;
/// - takeover screen ("已被其他设备接管"): a short-text button matching
///   下一步/确认/进入 (or English equivalents).
const _kDeepLinkTimeout = Duration(seconds: 10);
const _kDeepLinkPollInterval = Duration(milliseconds: 700);

/// Builds the injected deep-link script. [sessionId] and [title] are
/// embedded via [jsonEncode] so quotes/newlines cannot break out of the
/// JS string literals.
String buildDeepLinkJs(String sessionId, String? title) {
  final sid = jsonEncode(sessionId);
  final name = jsonEncode(title ?? '');
  return '''
(function () {
  var SID = $sid;
  var TITLE = $name;
  function txt(el) {
    return ((el && (el.innerText || el.textContent)) || '').trim();
  }
  // Takeover screen ("已被其他设备接管"): click 下一步/确认/进入.
  var bodyTxt = txt(document.body).slice(0, 4000);
  if (/接管/.test(bodyTxt) || /taken over by another/i.test(bodyTxt)) {
    var btns = document.querySelectorAll('button');
    for (var i = 0; i < btns.length; i++) {
      var t = txt(btns[i]);
      if (t && t.length <= 8 &&
          /^(下一步|确认|进入|Next|Confirm|Enter|Continue)\$/.test(t)) {
        btns[i].click();
        return 'takeover';
      }
    }
  }
  // Already viewing the target task.
  var active = document.querySelector('[data-mobile-active-task="true"]');
  if (active) {
    var atid = active.getAttribute('data-testid') || '';
    var akey = active.getAttribute('data-task-item-key') || '';
    if (atid.indexOf(SID) >= 0 || akey.indexOf(SID) >= 0) return 'already';
  }
  // Main list item whose testid / task-item-key contains the session id.
  var nodes = document.querySelectorAll('li[data-testid], [data-task-item-key]');
  for (var j = 0; j < nodes.length; j++) {
    var n = nodes[j];
    var tid = n.getAttribute('data-testid') || '';
    var key = n.getAttribute('data-task-item-key') || '';
    if (tid.indexOf(SID) >= 0 || key.indexOf(SID) >= 0) {
      (n.querySelector('button') || n).click();
      return 'navigated';
    }
  }
  // First-screen task picker: visible button whose text matches the title.
  if (TITLE.length >= 4) {
    var btns2 = document.querySelectorAll('button');
    for (var k = 0; k < btns2.length; k++) {
      var bt = txt(btns2[k]);
      if (bt && bt.indexOf(TITLE) >= 0 && btns2[k].offsetParent !== null) {
        btns2[k].click();
        return 'titled';
      }
    }
  }
  return 'pending';
})()
''';
}

/// Full-screen web remote control page. The official ZCode web app owns the
/// entire conversation protocol; we only load the device URL — plus an
/// injected deep-link that clicks through to [targetSessionId] once the
/// page is interactive. keepAlive keeps the session warm so reopening the
/// same device is instant.
class RemotePage extends StatefulWidget {
  final Device device;
  final String? targetSessionId;
  final String? targetTitle;
  const RemotePage({
    super.key,
    required this.device,
    this.targetSessionId,
    this.targetTitle,
  });

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  InAppWebViewController? _controller;
  double _progress = 0;
  bool _hasError = false;
  String? _errorDescription;

  Timer? _deepLinkTimer;
  int _deepLinkTicks = 0;
  bool _deepLinkDone = false;

  @override
  void dispose() {
    _deepLinkTimer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------ deep-link

  void _startDeepLink() {
    if (widget.targetSessionId == null ||
        _deepLinkDone ||
        _deepLinkTimer != null) {
      return;
    }
    _deepLinkTicks = 0;
    _deepLinkTimer = Timer.periodic(_kDeepLinkPollInterval, (_) {
      _deepLinkTicks += 1;
      if (_deepLinkTimer == null) return;
      if (_kDeepLinkPollInterval * _deepLinkTicks >= _kDeepLinkTimeout) {
        // Give up silently; the default view is very likely the last-open
        // conversation anyway (server restores by mobile-view-state).
        _stopDeepLink();
        return;
      }
      unawaited(_pollDeepLink());
    });
  }

  void _stopDeepLink() {
    _deepLinkTimer?.cancel();
    _deepLinkTimer = null;
  }

  Future<void> _pollDeepLink() async {
    final controller = _controller;
    if (controller == null || !mounted) return;
    dynamic res;
    try {
      res = await controller.evaluateJavascript(source: _deepLinkJs());
    } catch (_) {
      return; // page navigating; retry on the next tick
    }
    if (!mounted) return;
    final status = res is String ? res : '';
    switch (status) {
      case 'navigated':
      case 'already':
      case 'titled':
        _deepLinkDone = true;
        _stopDeepLink();
      case 'takeover':
        break; // keep polling — the list appears after taking over
      default:
        break;
    }
  }

  String _deepLinkJs() =>
      buildDeepLinkJs(widget.targetSessionId ?? '', widget.targetTitle);

  /// Ensures the device URL carries its `theme=` query when present so the
  /// official web remote opens in the matching color scheme.
  String get _launchUrl {
    final raw = widget.device.url;
    final theme = widget.device.params?.theme;
    if (theme == null || theme.isEmpty) return raw;
    final uri = Uri.parse(raw);
    if (uri.queryParameters['theme'] == theme) return raw;
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      'theme': theme,
    }).toString();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final linking = _deepLinkTimer != null;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.device.label,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(linking ? tr(context, 'tasks.deepLinking') : 'zcode.z.ai',
                style: TextStyle(fontSize: 11, color: ZInk.faint(context))),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller?.reload(),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'browser') {
                await launchUrl(Uri.parse(_launchUrl),
                    mode: LaunchMode.externalApplication);
              } else if (v == 'reload') {
                await _controller?.reload();
              }
            },
            itemBuilder: (c) => [
              PopupMenuItem(
                  value: 'browser', child: Text(tr(context, 'devices.menu.browser'))),
              PopupMenuItem(
                  value: 'reload', child: Text(tr(context, 'remote.reload'))),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: (_progress < 1 && !_hasError) || linking
              ? const LinearProgressIndicator(
                  minHeight: 2,
                  color: ZColors.sky500,
                  backgroundColor: Colors.transparent,
                )
              : const SizedBox(height: 2),
        ),
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest:
                URLRequest(url: WebUri(_launchUrl)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              databaseEnabled: true,
              useHybridComposition: true,
              // Keep the page alive across list<->remote navigation.
              // (incognito must stay false so DOM storage persists pairing.)
              incognito: false,
              supportZoom: false,
              mediaPlaybackRequiresUserGesture: false,
            ),
            onWebViewCreated: (c) => _controller = c,
            onLoadStop: (c, url) {
              setState(() => _progress = 1);
              _startDeepLink();
            },
            onProgressChanged: (c, p) =>
                setState(() => _progress = p / 100),
            onReceivedError: (c, request, error) {
              if (request.isForMainFrame ?? true) {
                setState(() {
                  _hasError = true;
                  _errorDescription = error.description;
                });
              }
            },
          ),
          if (_hasError)
            Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off,
                      size: 48, color: ZInk.ghost(context)),
                  const SizedBox(height: 16),
                  Text(tr(context, 'remote.error.title'),
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: ZInk.solid(context))),
                  const SizedBox(height: 8),
                  Text(
                    _errorDescription?.isNotEmpty == true
                        ? _errorDescription!
                        : tr(context, 'remote.error.hint'),
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 13, color: ZInk.faint(context)),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () {
                      setState(() {
                        _hasError = false;
                        _progress = 0;
                      });
                      _controller?.reload();
                    },
                    child: Text(tr(context, 'tasks.retry')),
                  ),
                ],
              ),
            ),
        ],
      ),
      backgroundColor:
          isDark ? ZColors.darkBackground : ZColors.lightBackground,
    );
  }
}
