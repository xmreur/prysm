import 'dart:io';

import 'package:flutter/foundation.dart';

class VideoPreviewSupport {
  VideoPreviewSupport._();

  /// Platforms with a registered video_player implementation.
  static bool get canPlayInApp {
    if (kIsWeb) return true;
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows;
  }

  /// video_thumbnail only supports mobile native platforms.
  static bool get canUseVideoThumbnailPlugin {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }
}
