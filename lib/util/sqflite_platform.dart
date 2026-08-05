import 'package:sqflite_common_ffi/sqflite_ffi.dart';

bool _ffiInitialized = false;

/// Ensures sqflite uses the FFI backend on every platform before
/// [openDatabase].
///
/// The app loads the SQLCipher build through `package:sqlite3`, which is the
/// same library the FFI factory talks to, so the FFI factory is used on all
/// platforms — including Android and iOS. The former `dart:io` platform check
/// for Android/iOS is gone, and with it the `dart:io` import.
void ensureSqflitePlatformInitialized() {
  if (_ffiInitialized) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  _ffiInitialized = true;
}
