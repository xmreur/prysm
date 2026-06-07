import 'dart:io';

import 'package:flutter/foundation.dart';

class QrPlatform {
  QrPlatform._();

  /// Camera QR scanning is only supported on Android and iOS.
  static bool get isScanSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);
}
