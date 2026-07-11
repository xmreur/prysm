import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum LogLevel {
  debug(500),
  info(800),
  warning(900),
  error(1000),
  fatal(1200);

  const LogLevel(this.value);
  final int value;
}

class Logging {
  Logging._();

  static LogLevel minimumLevel = kReleaseMode ? LogLevel.info : LogLevel.debug;
  static int _sequence = 0;
  static File? _logFile;

  static Future<void> init() async {
    final tempDir = await getTemporaryDirectory();
    final now = DateTime.now();
    final filename = 'prysm_chat_${_timestampForFile(now)}.log';
    final file = File('${tempDir.path}/$filename');

    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }

    _logFile = file;
    _logFile!.writeAsStringSync(
      '=== Prysm Chat log started at ${_timestampForLine(now)} ===\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  static String _timestampForFile(DateTime now) {
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    return '$y$m${d}_$h$min$s';
  }

  static String _timestampForLine(DateTime now) {
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    final ms = now.millisecond.toString().padLeft(3, '0');
    return '$y-$m-$d $h:$min:$s.$ms';
  }

  static bool _shouldLog(LogLevel level) {
    if (level == LogLevel.debug && !kDebugMode) return false;
    return level.value >= minimumLevel.value;
  }

  static String _prefix(LogLevel level, String fileAlias) {
    final source = fileAlias.trim();
    switch (level) {
      case LogLevel.debug:
        return 'DEBUG [$source]';
      case LogLevel.info:
        return 'INFO [$source]';
      case LogLevel.warning:
        return 'WARNING [$source]';
      case LogLevel.error:
        return 'ERROR [$source]';
      case LogLevel.fatal:
        return 'FATAL [$source]';
    }
  }

  static void _appendSync(String text) {
    final file = _logFile;
    if (file == null) return;
    try {
      file.writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static void _write(
    LogLevel level,
    String message,
    String fileAlias, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!_shouldLog(level)) return;

    final now = DateTime.now();
    final formatted =
        '[${_timestampForLine(now)}] ${_prefix(level, fileAlias)}: $message';

    if (kDebugMode) {
      debugPrint(formatted);
      if (error != null) debugPrint('error: $error');
      if (stackTrace != null) debugPrint('$stackTrace');
    }

    developer.log(
      formatted,
      name: fileAlias.trim(),
      level: level.value,
      time: now,
      sequenceNumber: ++_sequence,
      error: error,
      stackTrace: stackTrace,
    );

    final buffer = StringBuffer(formatted);
    if (error != null) buffer.write('\nerror: $error');
    if (stackTrace != null) buffer.write('\nstackTrace:\n$stackTrace');

    _appendSync(buffer.toString());
  }

  static void debug(
    String message,
    String fileAlias, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _write(
      LogLevel.debug,
      message,
      fileAlias,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void info(
    String message,
    String fileAlias, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _write(
      LogLevel.info,
      message,
      fileAlias,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void warning(
    String message,
    String fileAlias, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _write(
      LogLevel.warning,
      message,
      fileAlias,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void error(
    String message,
    String fileAlias, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _write(
      LogLevel.error,
      message,
      fileAlias,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void fatal(
    String message,
    String fileAlias, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    _write(
      LogLevel.fatal,
      message,
      fileAlias,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static String? get currentLogFilePath => _logFile?.path;
}
