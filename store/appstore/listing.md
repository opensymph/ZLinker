# App Store listing draft

Bundle ID: `org.songsong.zremote`  
Channel build (signed on a Mac with your distribution cert):

```bash
flutter build ipa --release --dart-define=APP_CHANNEL=appstore
```

Unsigned CI artifact (for smoke-testing only):

```text
zremote-vX.Y.Z-ios-unsigned.zip   # from the Release workflow
```

Fill `appStoreId` in `lib/update/app_channel.dart` once the listing exists
so in-app "check for updates" can deep-link to the store.

## Subtitle (30 chars)

Native remote for ZCode

## Description

ZRemote brings ZCode remote control to iPhone and iPad. Browse devices
with live status, open the official-style task list, and continue
conversations natively — streaming replies, tool diffs, queues and
permissions — with the web remote still one tap away.

## Keywords

ZCode,remote,AI,coding,developer,chat,device

## Privacy

URLs and credentials stay on-device. See
https://privacy.songsong.org/en.html

## Submit

1. Create the App Store Connect record
2. Archive & upload a signed IPA (Xcode / Transporter)
3. Attach screenshots from `docs/screenshots/`
4. Set age rating, export compliance, review notes
5. Submit for review

> Publication requires an Apple Developer Program membership. The Release
> workflow ships an unsigned iOS zip for smoke tests; signed App Store
> uploads remain a maintainer step.
