import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _ffiInitialized = false;

/// Ensures sqflite uses the FFI backend on desktop before [openDatabase].
void ensureSqflitePlatformInitialized() {
  if (Platform.isAndroid || Platform.isIOS) return;
  if (_ffiInitialized) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  _ffiInitialized = true;
}
