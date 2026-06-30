import 'dart:io';

bool get isDesktopPlatform =>
    !Platform.isAndroid && !Platform.isIOS;
