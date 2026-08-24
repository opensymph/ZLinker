# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.0] - 2026-08-24

### Added

- **Clipboard offer-to-add**: on resume, if the clipboard holds a remote
  URL that is not already saved, a snackbar offers to add it.
- **Drag-to-reorder + pin devices**: `ReorderableListView` with drag
  handles; pin/unpin from the overflow menu (pinned float to the top).
- **Per-device `theme=dark|light`**: URL parameter already parsed; opening
  a device now wraps the route in the matching theme and injects `theme=`
  into the WebView launch URL.
- **Android home-screen widget**: quick-open up to three devices via
  `zremote://device/<id>` (`ZRemoteWidgetProvider` + `home_widget` /
  `app_links`).
- **iOS unsigned artifact** in the Release workflow (`macos-latest`,
  `flutter build ios --no-codesign`, zip uploaded alongside the APK).
- **Store listing drafts** under `store/play/` and `store/appstore/`.
- **README screenshots + demo GIF** (`docs/screenshots/`).

## [1.4.0] - 2026-08-24

### Added

- **Dual layouts aligned with the official web page** (PR #1,
  `task_list_page.dart`, live-page verified at the Tailwind `md` = 768px
  breakpoint):
  - **<768** mobile card list — AppBar「ZCode 远程控制」+ green connected
    subtitle, connection explanation card, workspace cards with status
    pills, compact relative times, push-style chat navigation.
  - **≥768** desktop IDE sidebar (264px, `#1E1E1E`) — 新建任务 / 搜索 /
    项目 tree with selected highlight, 1px `#333` divider, rounded right
    chat pane (min-width 320).
- **Pinned task group** (「已置顶」section card) above workspace cards on
  the mobile list, driven by `SessionEntry.raw['pinned']`.
- Chat page second header shows a workspace folder chip; 「更多」leads
  with 重命名任务 / 复制任务 ID / 复制任务链接 (official parity).

## [1.3.1] - 2026-08-24

### Added

- **Responsive dual-pane layout** (`task_list_page.dart`): at ≥768px
  (official Tailwind `md` breakpoint, verified 767 vs 768 against the
  live page) the task list becomes the official desktop layout — a 264px
  sidebar (`--workspace-sidebar-panel-width`) with its own slim header,
  a 1px divider, and the chat page embedded side by side in the right
  pane (`ChatPage.embedded`, no back button). Below 768 the push-style
  phone navigation is unchanged.
- **Pinned task group** on the list: the official "已置顶" section card
  (title, workspace · time, phase pill) above the workspace cards,
  driven by `SessionEntry.raw['pinned']`.
- Long-press on any task row opens a bottom-sheet action sheet
  (停止/暂停/恢复, enabled per phase) — replaces the per-row ⋮ menu,
  matching the official mobile list which has no row menus.

### Changed

- **List page tightening to the official 390px layout**: the connection
  status card is now always visible (green online state + explanation
  copy, not only when degraded); section title 16/w600, stats and rows
  bumped (row title 14.5, card padding 16, radius 8, page inset 12);
  the current task row (latest running, else most recent) gets the
  official rounded white/10 highlight instead of the sky tint; task-row
  phase pills use the official solid style (#46BF72 black-text 已完成,
  #001D3D white-text 运行中, 10px label, h18).
- **Chat content column** (`chat_page.dart`): messages cap at 848px and
  the composer at 864px, centered inside the pane like the official
  desktop page; composer chips (mode/model/thought) are icon-only 28×28
  below 640px and icon+label above, and model/thought labels now prefer
  the friendly option names from `WorkspacePrep` (GLM-5.3, 最高).

### Fixed

- User message bubbles no longer render 14 lines tall for short texts:
  `SelectableText(maxLines:)` inflates to maxLines height inside
  unbounded parents (ListView); collapsed long texts now use a
  non-scrollable height clip instead (regression tests cover both).

## [1.3.0] - 2026-08-24

### Added

- **Native conversation page** (`lib/ui/chat/chat_page.dart`) — the chat
  experience moves off the WebView onto the Conversation V4 protocol
  (ported structure from the zemote reference, restyled to the official
  mobile layout with `theme.dart` tokens only):
  - Turn grouping (`userInput` opens a turn, assistant rows merge even
    across server `turnId` bumps), ordered assistant parts (reasoning →
    text → tool → text), feedback only on the last text segment.
  - Streaming markdown via `flutter_markdown` with self-drawn code-block
    header (language tag + copy), inline-code pills; tool-call diffs via
    the ported `extractDiff` (old/new alias keys + `structuredPatch`) and
    a token-styled `DiffView`.
  - Official-looking rows: 思考过程 collapsible strip, tool summaries
    (已写入 file +N / 终端 · cmd / 探索 · N 文件) with status icons,
    turn footers (已工作 N 分 N 秒 + phase pill + expandable file-change
    bar with 撤销/rewind), centered timeline capsules, HH:mm separators,
    user bubbles with outside copy/edit affordances and long-text fold.
  - Composer: rounded container, 提出后续修改要求 hint, bottom row with
    add-context, mode chip, usage ring (context %), model chip, thought
    chip, send/stop; slash commands (`/compact`, `/goal …`, workspace
    commands) and `$skill` picker from `prepareWorkspace` + `skills.list`.
  - pendingInteractions cards (permission options / question chips /
    free-text), held-queue bar (auto-drain toggle, send-now, edit,
    delete), goal banner, background-works bar, reconnect banner, and a
    full-screen takeover (KICK) overlay with manual reconnect.
  - Long-press actions: edit-resend (`editUserQuery`), retry turn, fork,
    rewind-to-here (`applyFileRewind`), file changes sheet; "更多" menu
    with rename / pin / archive / mark-unread (`TaskCommandsPort`, method
    names NOT live-confirmed — MethodProbe candidates), copy path /
    session id, compact, usage, plans.
  - Draft mode: ➕ on a workspace opens a draft chat; model/mode/thought
    picked up front ride along as `createSession.config`, first message
    sent as `firstInput`; older-history paging via `rowsRange`.
- **ChatGateway seam** (`device_session.dart`): the conversation surface
  the chat UI drives (subscribe / commands / attachments / task ops);
  `DeviceSession` implements it against the live transport (subscription
  cache, cleanup on suspend/workspace switch), tests fake it. Also
  exposes `conversation` / `bridge` getters and `WorkspacePrep.fromMap`.
- **Official-mobile-layout task list** (`task_list_page.dart`):
  connection banner card, "当前设备上的工作区和任务" header with
  N 工作区 · M 任务 stats, collapse-all / tidy (running-first sort) /
  refresh; workspace cards (name + 本地 badge, folder + path,
  updated-at, task count, chevron, ➕ draft); task rows with phase pills
  (running spinner / check / failed colors), relative time,
  current-task highlight. Tapping a task now opens the **native** chat
  (no WebView suspend); the web version remains in the overflow menu and
  fallback paths.
- Notification taps and off-peak "查看结果" open the native chat page
  directly (WebView deep-link only when no protocol session exists).
- i18n: ~120 new `chat.*` / `tasks.*` keys, zh + en.

### Changed

- Version 1.3.0+4; new deps `flutter_markdown`, `markdown`, `file_picker`
  (any-file attachments, 384KB-chunk upload with progress).
- `theme.dart`: added `ZColors.warning` and
  `ZInk.tile/hairline/codeInlineBg/codeBlockBg/codeText` tokens used by
  the chat surfaces.

### Tests

- 200 total (was 172): extractDiff suite, DiffView widget, markdown
  renderer, TaskCommandsPort probing (candidate resolution, arg shapes,
  rethrow semantics), chat-page widget tests over a fake gateway + real
  `ConversationState` fed by hand (grouping, interactions, queue, draft
  createSession, kicked overlay, subscribe-failure banner), task-list
  route tests over a `FakeDeviceSession` override.

## [1.2.0] - 2026-08-23

### Added

- Server-side automations (设备自动化): full CRUD against the desktop
  `zcode-cron-scheduler` — cron / interval+cap / one-shot-delay triggers,
  optional model/mode/thoughtLevel/targetTaskId, enable toggle, edit and
  delete-with-confirm; humanized trigger summaries; unavailable state
  guides to local scheduled messages. Entry from the task-list menu and
  the combined scheduled page (`automation.dart` port with probed method
  names; `listAllAutomations` live-confirmed).
- Off-peak tasks (闲时任务): submit queued runs for compute-rich windows —
  title/prompt/model/earliest/keepAwake/permission form with three quick
  templates, live queue position (#N), pause / resume / cancel, history
  with duration, official error states (仅 Coding Plan 可用 / 额度已用尽 /
  服务暂不可用), quota header, and view-result deep-link into the produced
  session (`off_peak.dart` port + error classification).
- Local notifications (`flutter_local_notifications`): three separately
  silenceable channels (task events / off-peak events / automation
  results), Android 13+ runtime permission asked lazily, tap on a
  notification deep-links to the conversation, master + per-channel
  switches in settings; task events ride the sessions-index stream,
  off-peak (60s) and automation (120s) results poll — pure diff rules in
  `notify_rules.dart`, glue in `notification_hub.dart`.
- Combined scheduling page: 设备自动化 + 本地定时发送 coexisting sections.
- ~58 new tests (automation/off-peak ports with fake channels, pages with
  fake hosts, notification rules + hub glue, settings switches).

## [1.1.0] - 2026-08-23

### Added

- Hybrid architecture: a pure-Dart protocol stack (relay, pairing proof,
  rpc-frame, IPC codec, conversation V4) powers the glanceable layer natively,
  while conversations stay in the official web remote.
- Native device list with live online status and running-task badges.
- Native task list with stop / pause / resume controls.
- Deep-link from a task card into the web remote, opened at that exact task;
  graceful fallback to plain web mode when the protocol shifts.
- Usage stats, device usage, and model providers pages.
- Scheduled tasks store and page.
- Settings, UI settings, and About pages.
- In-app update checker (`package_info_plus` + GitHub Releases).
- ~100 new tests (protocol, stores, settings, update service, deep-link JS).

### Changed

- Android application id / namespace: `org.songsong.zremote`.
- README (EN + zh-CN) rewritten around the hybrid positioning.

## [1.0.1] - 2026-08-23

### Added

- App icon in the official ZCode style: dark `#161616` background, bold
  geometric white "Z", sky-blue broadcast accent; generated for all Android
  densities (classic + adaptive) and iOS via `flutter_launcher_icons`.
- `tool/icon_gen.dart` — regenerates the icon source art from code.

### Changed

- README (English + 简体中文) rewritten: new tagline, no third-party project
  references.

## [1.0.0] - 2026-08-23

### Added

- Device list home: cards with name / host / last-used time; rename, delete,
  copy link, open in browser; device backup export / import (JSON).
- Add devices by camera QR scan, gallery QR decode (pure Dart), or pasting a
  remote-control URL; automatic de-duplication; unparseable URLs are still
  saved with a warning.
- Full-screen in-app WebView remote page (flutter_inappwebview) with loading
  progress bar, reload, and open-in-browser escape hatch; DOM storage
  persists the official page's pairing state.
- Official-theme design system extracted from the real ZCode web-remote
  bundle: Tailwind neutral gray scale + sky accent, dark `#161616` default,
  light and follow-system modes.
- Dark / light / system theme with persistence.
- Android + iOS projects, permissions, and display names configured.
- Unit tests (URL parsing, device store CRUD / persistence / import-export)
  and widget tests (empty state, device card, app boot).
- CI workflow (analyze + test) and release workflow (tag → APK → GitHub
  Release).
