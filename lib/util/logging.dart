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

  static const int _maxLogSize = 10 * 1024 * 1024;
  static LogLevel minimumLevel = kReleaseMode ? LogLevel.info : LogLevel.debug;
  static int _sequence = 0;
  static File? _logFile;

  /// Redacts a Tor v3 onion address for log output: keeps the first 6
  /// characters and replaces the rest with an ellipsis, so the full address
  /// can never be reconstructed from logs. Call sites redact explicitly and
  /// [_write] scrubs any onion that slips through (e.g. inside an
  /// exception's toString()) before any sink sees it, so the guarantee
  /// holds on disk, on the debug console and in developer.log.
  static String redactOnion(String onion) {
    if (onion.length <= 6) return onion;
    return '${onion.substring(0, 6)}…';
  }

  /// Matches a Tor v3 onion address (56 base32 chars + '.onion') embedded
  /// anywhere in a log line, so the write path can redact it even when a
  /// call site only interpolated an error object whose toString() carries
  /// the address.
  static final RegExp _onionV3 =
      RegExp(r'[a-z2-7]{56}\.onion', caseSensitive: false);

  /// Replaces every full v3 onion in [text] with its redacted form. This is
  /// the single home of the redaction: [_write] applies it once, up front,
  /// so every sink (debug console, developer.log, log file) receives only
  /// scrubbed text.
  static String _scrub(String text) {
    return text.replaceAllMapped(_onionV3, (m) => redactOnion(m.group(0)!));
  }

  static Future<void> init() async {
    final tempDir = await getTemporaryDirectory();
    final now = DateTime.now();
    final filename = 'prysm_chat.log';
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
      // Text already arrived scrubbed from _write; this method only appends.
      final line = '$text\n';
      if (file.lengthSync() + line.length > _maxLogSize) {
        _trimFront(file, line.length);
      }
      file.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static void _trimFront(File file, int neededSpace) {
    var content = file.readAsStringSync();
    while (content.length + neededSpace > _maxLogSize) {
      final nl = content.indexOf('\n');
      if (nl == -1) {
        content = '';
        break;
      }
      content = content.substring(nl + 1);
    }
    file.writeAsStringSync(content, flush: true);
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
    // Scrub once, up front: every sink below (debug console, developer.log,
    // log file) must only ever see redacted text, including onions embedded
    // in exception/stack strings that call sites interpolate unwittingly.
    final scrubbedLine = _scrub(formatted);
    final scrubbedAlias = _scrub(fileAlias.trim());
    final scrubbedError = error == null ? null : _scrub(error.toString());
    final scrubbedStack =
        stackTrace == null ? null : _scrub(stackTrace.toString());

    if (kDebugMode) {
      debugPrint(scrubbedLine);
      if (scrubbedError != null) debugPrint('error: $scrubbedError');
      if (scrubbedStack != null) debugPrint(scrubbedStack);
    }

    developer.log(
      scrubbedLine,
      name: scrubbedAlias,
      level: level.value,
      time: now,
      sequenceNumber: ++_sequence,
      error: scrubbedError,
      stackTrace: scrubbedStack == null
          ? null
          : StackTrace.fromString(scrubbedStack),
    );

    final buffer = StringBuffer(scrubbedLine);
    if (scrubbedError != null) buffer.write('\nerror: $scrubbedError');
    if (scrubbedStack != null) buffer.write('\nstackTrace:\n$scrubbedStack');

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
