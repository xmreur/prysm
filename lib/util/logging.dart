import 'package:flutter/foundation.dart';

class Logging {
  static void debug(String message, String? fileAlias) {
    if (kDebugMode) {
      print('🔹 DEBUG ${fileAlias ?? ''}: $message');
    }
  }

  static void info(String message, String? fileAlias) {
    print('🔵 INFO ${fileAlias ?? ''}: $message');
  }

  static void warning(String message, String? fileAlias) {
    print('🟡 WARNING ${fileAlias ?? ''}: $message');
  }

  static void error(String message, String? fileAlias) {
    print('🔴 ERROR ${fileAlias ?? ''}: $message');
  }

  static void fatal(String message, String? fileAlias) {
    print('🔴 FATAL ${fileAlias ?? ''}: $message');
  }
}


