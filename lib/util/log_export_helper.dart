import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:prysm/util/download_location.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/ui/core/prysm_toast.dart';

Future<void> exportLog(BuildContext context) async {
  final logPath = Logging.currentLogFilePath;
  if (logPath == null) {
    if (context.mounted) {
      showPrysmToast(context, 'No log file found');
    }
    return;
  }

  final logFile = File(logPath);
  if (!await logFile.exists()) {
    if (context.mounted) {
      showPrysmToast(context, 'No log file found');
    }
    return;
  }

  try {
    final dir = await DownloadLocation.resolveDirectory();
    if (dir == null) {
      if (context.mounted) {
        showPrysmToast(context, 'Downloads folder not available');
      }
      return;
    }

    final dest = File('${dir.path}/prysm_chat.log');
    await logFile.copy(dest.path);

    if (context.mounted) {
      showPrysmToast(context, 'Log saved to ${dest.path}');
    }
  } catch (e) {
    if (context.mounted) {
      showPrysmToast(context, 'Failed to export log: $e');
    }
  }
}
