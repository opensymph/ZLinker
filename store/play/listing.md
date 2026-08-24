# Play Store listing draft

Package ID: `org.songsong.zremote`  
Channel build:

```bash
flutter build appbundle --release --dart-define=APP_CHANNEL=play
```

## Short description (80 chars)

Native ZCode remote — devices, tasks, and conversations on your phone.

## Full description

ZRemote is an open-source remote for ZCode. Keep a device list with live
online status, browse workspaces and tasks in the official mobile layout,
and chat natively over Conversation V4 (streaming markdown, tool diffs,
queues, interactions). The official web remote stays one tap away as a
fallback.

Features:
• Device cards with online dots and running-task badges
• Native task list + dual-pane desktop layout
• Native conversations (Conversation V4)
• Server automations & off-peak tasks
• Local notifications with tap-to-open
• Clipboard offer-to-add for remote URLs
• Home-screen quick-open widget
• Dark / light / system themes; per-device theme= URL

Privacy: device URLs stay on your phone (Android backups disabled). No
accounts, no telemetry.

## Assets checklist

- [ ] Feature graphic 1024×500
- [ ] Phone screenshots (see `docs/screenshots/`)
- [ ] Tablet screenshots (optional)
- [ ] High-res icon 512×512 (`assets/icon/icon.png`)

## Submit

1. Create a Play Console app for `org.songsong.zremote`
2. Upload the AAB from the play-channel build
3. Attach the listing copy above and screenshots
4. Complete Data safety / content rating questionnaires
5. Roll out to internal testing, then production

> Store publication requires a Google Play developer account owned by the
> maintainer. This repo ships store-ready channel builds and listing
> drafts; the final console click is intentional and manual.
