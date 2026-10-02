import 'package:flutter/foundation.dart';

/// Device identity sent during relay auth and mobile-view-state updates.
///
/// The web client reports itself as a browser; ZLinker identifies itself
/// honestly so the desktop can show the real connected client.
const remoteAppName = 'zlinker';

/// Real runtime platform (android / ios / web / windows / ...), defaults to
/// `web` when unknown so the handshake stays valid on exotic targets.
String remotePlatformName() {
  if (kIsWeb) return 'web';
  // If-chain instead of a switch: the ohos fork adds TargetPlatform.ohos to
  // the enum, so a default clause is unreachable on stock Flutter (CI lint)
  // yet REQUIRED on ohos — the chain keeps both compilers happy.
  final platform = defaultTargetPlatform;
  if (platform == TargetPlatform.android) return 'android';
  if (platform == TargetPlatform.iOS) return 'ios';
  if (platform == TargetPlatform.windows) return 'windows';
  if (platform == TargetPlatform.macOS) return 'macos';
  if (platform == TargetPlatform.linux) return 'linux';
  if (platform == TargetPlatform.fuchsia) return 'fuchsia';
  return 'ohos';
}
