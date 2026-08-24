<div align="center">

# ZRemote

**Full-protocol native remote — conversations included.**

The open-source remote for **ZCode** — a native device list with live
online status and running-task badges, a native task list with
stop / pause / resume, and **fully native conversations** over the
Conversation V4 protocol: streaming markdown, tool calls with diffs,
model/mode/thought switching, queues, interactions, attachments and
history paging. The official web remote stays one tap away as a
fallback for anything the native path can't do yet.

[简体中文](README.zh-CN.md) · [Why ZRemote?](#-why-zremote) · [Features](#-features) · [Quick Start](#-quick-start) · [Architecture](#-architecture) · [Roadmap](#️-roadmap)

[![Release](https://img.shields.io/github/v/release/opensymph/ZRemote?style=flat-square&logo=github&color=blue)](https://github.com/opensymph/ZRemote/releases)
[![Build](https://img.shields.io/github/actions/workflow/status/opensymph/ZRemote/ci.yml?style=flat-square&label=build)](https://github.com/opensymph/ZRemote/actions/workflows/ci.yml)
[![Stars](https://img.shields.io/github/stars/opensymph/ZRemote?style=flat-square&color=yellow)](https://github.com/opensymph/ZRemote/stargazers)
[![Forks](https://img.shields.io/github/forks/opensymph/ZRemote?style=flat-square&color=orange)](https://github.com/opensymph/ZRemote/forks)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS-lightgrey?style=flat-square)](#-quick-start)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.44%2B-blue?style=flat-square&logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.12%2B-0175C2?style=flat-square&logo=dart)](https://dart.dev)

</div>

---

## 💡 Why ZRemote?

Two bad options used to exist: re-implement the whole private protocol
(relay handshakes, pairing proofs, frame transport, V4 snapshots) and
break on every protocol change — or ship a dumb launcher with no status,
no task list, no controls.

**ZRemote takes the hybrid bet.** A battle-tested pure-Dart protocol
stack powers everything natively — device status, the live task list,
stop/pause/resume, usage, model providers, and since 1.3 the full
conversation experience (streaming rows, commands with CAS retry,
attachments, model switching). The official web remote remains as a
per-task escape hatch; if the protocol ever moves, the native path
degrades gracefully to web mode and the app keeps working.

- 🟢 **Native status, zero effort** — every card shows an online dot and
  a running-task badge from the live sessions-index subscription.
- 📋 **A real task list** — the official mobile layout: workspace cards
  with 本地 badges and paths, task rows with phase pills and relative
  times, an always-on connection banner, a pinned group, long-press task
  actions, collapse-all / tidy / refresh — and above 768dp it flips to a
  dual-pane layout (264dp sidebar + embedded chat).
- 💬 **Native conversations** — the whole V4 surface in your language of
  widgets: grouped turns, streaming markdown, 思考过程 strips, tool
  summaries with diffs, pending interactions, held queue, feedback,
  retry/fork/rewind, slash commands and skills, usage ring, history
  paging — plus a draft composer that creates the task on first send.
- 🧬 **Protocol shifts can't brick it** — handshake failure flips a card
  into "use the web version" mode; the WebView path has no protocol
  dependencies at all. There's also a per-device "open web version"
  escape hatch and a global native-list switch.
- 🔐 **Credentials stay on your phone** — device URLs live in local
  storage only (Android backups disabled on purpose); no servers, no
  telemetry, no accounts.

> *Native where it pays, official where it matters, web when it breaks.*

Sounds good? **Star ⭐ the repo** to follow along.

---

## ✨ Features

| | |
|---|---|
| 📋 **Device list** | Cards with device name, host, last-used time, online status dot and running-task badge; drag-to-reorder, pin; rename, delete, copy link, open in browser; clipboard offer-to-add; export / import your device backup as JSON |
| ➕ **Add by scan, paste, or screenshot** | Camera QR scan (`mobile_scanner`), pure-Dart gallery QR decode (`zxing2`), or paste a URL — with de-duplication; unparseable links are still saved, never lost |
| 📊 **Native task list** | Official mobile layout: workspace cards (本地 badge, path, updated-at, task count), task rows with phase pills (running spinner / ✓ / failed), relative times, current-task highlight; always-on connection banner; pinned group; long-press bottom sheet (stop / pause / resume); collapse-all / tidy / refresh; ≥768dp dual pane (264dp sidebar + embedded chat) |
| 💬 **Native conversation** | Full Conversation V4: grouped turns with streaming markdown, 思考过程 strips, tool-call summaries + diffs, file-change bars with rewind, feedback (👍/👎/fork), pending interactions (permissions & questions), held queue with auto-drain, model / mode / thought / follow-up switching, attachments, slash commands + `$skills`, usage ring, context bar, older-history paging, takeover overlay, retry / edit-resend / fork / rewind long-press actions |
| 🆕 **Draft composer** | ➕ on a workspace starts a draft task: model/mode/thought picked up front, `createSession` fires with the first message |
| 🎯 **Web fallback everywhere** | Every task can still be opened in the official web remote (suspend → deep-link → resume); the native path never suspends the link |
| 📈 **Usage & model providers** | Per-device entitlement snapshot (remaining quota, limits, subscription) and model-provider management over the workspace bridge |
| 🤖 **Server-side automations** | Full CRUD of desktop cron/interval/one-shot automations (`zcode-cron-scheduler`): humanized trigger summaries, enable toggle, edit / delete with confirm — they fire on the desktop, app not required online |
| 🌙 **Off-peak tasks** | Submit queued runs for compute-rich windows (Coding Plan, monthly quota): live queue position (#N), pause / resume / cancel, history with duration, official error states (subscription / quota / unavailable), view-result deep-links into the produced session; three quick templates included |
| 🔔 **Local notifications** | Task completed/failed, off-peak results and automation runs pushed to the phone (three separately-silenceable channels); tapping a notification opens the native conversation — web-remote browser notifications never reach a phone |
| ⏰ **Scheduled messages** | Local timer-based send to a device at a chosen time (app-side timer + `createSession`); works even when the target device is offline, complements server-side automations |
| ⚙️ **Settings & about** | Theme (dark / light / system), language (中文 / English), native-list switch, channel-aware update check, licenses, privacy policy, local usage statistics |
| 🌐 **In-app web remote** | Fullscreen `flutter_inappwebview` with progress bar, reload, "open in browser" escape hatch; DOM storage keeps the official page's pairing across opens |
| 🎨 **Official design tokens** | Neutral gray scale + sky accent extracted from the real bundle; dark `#161616` default |
| 📱 **Android + iOS, store-ready** | Channel builds (`github` / `play` / `appstore`), privacy manifest, bilingual permission strings; no self-install APK code path anywhere |

One terminal per device: the server allows a single connection per
device. The native chat keeps that link live (no suspension); only the
explicit "open web version" action suspends it and reconnects about a
second after the WebView closes. Multiple devices run in parallel, each
with its own connection.

---

## 📸 Screenshots

<p align="center">
  <img src="docs/screenshots/01-list-mobile.png" width="240" alt="Mobile task list" />
  <img src="docs/screenshots/02-chat-mobile.png" width="240" alt="Mobile chat" />
</p>

<p align="center">
  <img src="docs/screenshots/03-dual-pane.png" width="720" alt="Desktop dual-pane" />
</p>

<p align="center">
  <img src="docs/screenshots/demo.gif" width="320" alt="ZRemote demo" />
</p>

Mobile list → chat, and the ≥768dp IDE sidebar + chat pane. The native
UI mirrors the official remote layout (same tokens, breakpoints, chrome).

---

## 🚀 Quick Start

You need a desktop machine running **ZCode** (zcode.z.ai). Generate a remote
link there: ZCode → Remote Control → QR code / copy link. It looks like:

```text
https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...&mid=...&name=...
```

### Option A · Download a prebuilt APK

Grab the latest APK from
[Releases](https://github.com/opensymph/ZRemote/releases), install it on your
phone, and add your first device by scanning the QR code.

> ⚠️ Only install APKs from a Release you trust — a remote-control link is a
> device credential. Audit the code, or build it yourself (Option B).

### Option B · Build from source

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install) 3.44+
(Dart 3.12+). For Android builds: JDK + Android SDK. For iOS: a Mac with
Xcode.

```bash
git clone https://github.com/opensymph/ZRemote.git
cd ZRemote
flutter pub get

flutter run                       # debug on a connected device

# Distribution channels (update behavior differs):
flutter build apk --release                                            # github (default)
flutter build apk --release --dart-define=APP_CHANNEL=play             # Play Store
flutter build ipa --dart-define=APP_CHANNEL=appstore                   # on a Mac
```

Channel behavior for "check for updates": **github** checks GitHub
releases and opens the download in the browser; **play** / **appstore**
open the store listing. No build contains in-app APK download/install
code.

Inside the app: **Add device** → scan or paste → tap a card → the native
task list → tap a task → you're in the conversation.

```bash
flutter analyze   # zero warnings
flutter test      # all green (protocol unit tests included)
```

---

## 🧱 Architecture

```
┌──────────────────────────────────────────────────────────┐
│ UI (lib/ui)                                              │
│   devices_page · task_list_page · chat/ (native chat)    │
│   automations_page · off_peak_page ·                     │
│   settings / about / usage · device_usage ·              │
│   model_providers · scheduled · qr_scan                  │
├──────────────────────────────────────────────────────────┤
│ State (lib/state)                                        │
│   device_store — devices + persistence + backups         │
│   device_session — per-device connection state machine   │
│                    (connect / suspend / resume, retries, │
│                     ChatGateway seam for the chat UI)    │
│   scheduled_store — scheduled messages + scheduler       │
│   notification_hub — task/off-peak/automation →          │
│                      local notifications                 │
├──────────────────────────────────────────────────────────┤
│ Protocol (lib/protocol — ported, battle-tested)          │
│   relay_client · remote_client · conversation (V4)       │
│   channel_client · rpc_transport · ipc_codec · proof     │
│   automation · off_peak · task_commands · method_probe   │
│      (channel ports with probed method names)            │
├──────────────────────────────────────────────────────────┤
│ Notifications (lib/notifications)                        │
│   notification_service — 3 channels, permissions, taps   │
│   notify_rules — pure before/after event derivation      │
├──────────────────────────────────────────────────────────┤
│ Web fallback (remote_page)                               │
│   official ZCode Web Remote in a WebView                 │
│   + injected deep-link to the tapped session             │
│   — owned and updated by Zhipu, not by us                │
└──────────────────────────────────────────────────────────┘
```

```text
lib/
├── main.dart                  # entry: stores + session hub + scheduler
│                              #       + notification hub & deep-link taps
├── protocol/                  # pure-Dart ZCode remote protocol stack
│   ├── relay_client.dart      # wss relay: auth, pairing, heartbeat, reconnect
│   ├── remote_client.dart     # bootstrap · bridges · recovery · view-state
│   ├── conversation.dart      # Conversation V4: sessions-index, commands
│   ├── channel_client.dart    # IPC channel RPC
│   ├── automation.dart        # automations port (probed CRUD methods)
│   ├── off_peak.dart          # off-peak tasks port + error classification
│   ├── task_commands.dart     # task rename/pin/archive/unread (probed)
│   ├── method_probe.dart      # try-until-accepted channel method probing
│   ├── rpc_transport.dart     # rpc-frame fragmentation + crc32
│   ├── ipc_codec.dart         # value codec + frame parser
│   ├── connection_params.dart # remote URL parsing + relay ws derivation
│   ├── proof.dart · crc32.dart · device_info.dart · id.dart
├── state/
│   ├── device_store.dart      # device model + persistence + import/export
│   ├── device_session.dart    # DeviceSession + hub (one terminal per device)
│   │                          #   + automation/off-peak host interfaces
│   ├── scheduled_store.dart   # scheduled messages + MessageScheduler
│   └── notification_hub.dart  # sessions/off-peak/automation → notifications
├── notifications/
│   ├── notification_service.dart # 3 channels · permissions · tap payloads
│   └── notify_rules.dart         # pure before/after event derivation
├── ui/
│   ├── theme.dart             # official design tokens + dark/light themes
│   ├── ui_settings.dart       # locale + native-list/notification switches + tr()
│   ├── devices_page.dart      # device list with status dots & badges
│   ├── task_list_page.dart    # native task list (official mobile layout)
│   ├── chat/chat_page.dart    # native conversation (Conversation V4)
│   ├── chat/markdown_view.dart# markdown + code blocks (header + copy)
│   ├── chat/diff_view.dart    # tool-call diff extraction + renderer
│   ├── phase_pill.dart        # shared status pill (list + turn footers)
│   ├── remote_page.dart       # WebView fallback + deep-link injection
│   ├── automations_page.dart  # server-side automations (CRUD + toggles)
│   ├── off_peak_page.dart     # off-peak tasks (queue, quota, results)
│   ├── settings_page.dart · about_page.dart · usage_stats_page.dart
│   ├── device_usage_page.dart · model_providers_page.dart
│   ├── scheduled_page.dart · qr_scan_page.dart
└── update/                    # app channel + github release checker
```

~17,000 lines of Dart in `lib/`, ~4,200 lines of tests (protocol codecs,
state machines, delta application, stores, i18n, deep-link JS builder,
automation/off-peak/task-command ports, notification rules, chat-page
widget tests over a fake gateway + real ConversationState).

---

## 🗺️ Roadmap

- [x] English localization (in-app 中文 / English switch)
- [x] Native device status + running-task badges
- [x] Native task list with stop / pause / resume
- [x] Tap-to-conversation deep-link (WebView injection)
- [x] Scheduled messages (minimal automation)
- [x] Store-ready builds (channel split, privacy manifest)
- [x] Server-side automations (cron / interval / one-shot, full CRUD)
- [x] Off-peak tasks (queue position, quota, view-result deep-link)
- [x] Local notifications (task / off-peak / automation channels + tap deep-link)
- [x] Native conversation page (V4: streaming, tools, diffs, queue, interactions, attachments, model switching)
- [x] Official-mobile-layout task list (workspace cards + phase pills)
- [x] Screenshots + demo GIF in the README
- [x] Clipboard detection — offer to add when a remote URL is copied
- [x] Drag-to-reorder and pin devices
- [x] Per-device `theme=dark|light` URL parameter
- [x] Home-screen quick-open widget (Android)
- [x] iOS artifacts in the release workflow (unsigned `Runner.app` zip)
- [x] Store listing drafts + channel builds (`store/play`, `store/appstore`)
- [ ] Submit to Play Store / App Store (needs developer accounts — listing copy ready)

---

## 🤝 Contributing

Issues and PRs are welcome. Before submitting:

```bash
flutter analyze   # zero warnings
flutter test      # all green
```

Small, focused PRs land fastest. For UI work, keep the
[official design tokens](lib/ui/theme.dart) — that's the point. Protocol
changes should stay faithful to the reference implementation this stack
was ported from.

---

## 🙏 Acknowledgements

- **ZCode & the official web remote** — the protocol it speaks and the
  fallback experience.
- The Flutter ecosystem: `flutter_inappwebview`, `mobile_scanner`,
  `zxing2`, `shared_preferences`, `url_launcher`, `web_socket_channel`,
  `flutter_local_notifications`, `flutter_markdown`, `file_picker`.

> ⚠️ ZRemote is an independent, community tool. It is not affiliated with,
> endorsed by, or connected to Zhipu AI. Use it only with devices you own and
> in accordance with the ZCode terms of service.

[Privacy Policy](https://privacy.songsong.org/en.html) · [Terms of Service](https://privacy.songsong.org/tos-en.html)

---

## License

MIT © ZRemote contributors — see [LICENSE](LICENSE).
