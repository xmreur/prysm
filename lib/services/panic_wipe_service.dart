import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/hs_transfer_keys.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PanicWipeService {
  PanicWipeService._();

  static Future<void> wipeAll() async {
    await MessagesDb.closeForWipe();
    await PendingMessageDbHelper.closeForWipe();
    await DBHelper.closeForWipe();

    final docDir = await getApplicationDocumentsDirectory();
    final prysmDir = Directory(p.join(docDir.path, 'prysm'));
    for (final name in ['chat_app.db', 'messages.db', 'pending_messages.db']) {
      // The -wal/-shm sidecars can carry plaintext pages even when the main
      // file is encrypted; leaving them defeats the wipe. A leftover
      // $name.migrating must go too: if secureStorage.deleteAll() fails
      // after the files are gone, the next launch's recovery path would
      // verify that temp and rename it back into place — resurrecting the
      // database the user just panic-wiped.
      for (final suffix in ['', '-wal', '-shm', '.migrating']) {
        final file = File(p.join(prysmDir.path, '$name$suffix'));
        if (await file.exists()) {
          await file.delete();
        }
      }
    }

    const secureStorage = FlutterSecureStorage();
    await secureStorage.deleteAll();
    await PanicPinService.instance.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  /// Wipe for account transfer: [wipeAll] plus single-op source deactivation
  /// ([TorManager.deactivateForTransfer]: restarts suppressed, Tor stopped
  /// and verified dead, HS keys deleted and verified absent, all under one
  /// lock). Returns true only when deactivation is confirmed: the caller
  /// must NOT report transfer success on false (double-onion risk).
  static Future<bool> wipeForTransfer({dynamic torManager}) async {
    await wipeAll();
    try {
      if (torManager != null) {
        return await torManager.deactivateForTransfer() == true;
      }
      // No manager (e.g. tests): best-effort desktop file delete only.
      // Tor cannot be stopped or verified from here.
      if (Platform.isAndroid || Platform.isIOS) return false;
      final docDir = await getApplicationDocumentsDirectory();
      // ponytail: file lock lives inside deleteDirectory (HsTransferKeys.opMutex).
      return await HsTransferKeys.deleteDirectory(
        HsTransferKeys.hsDirForDocuments(docDir.path),
      );
    } catch (_) {
      return false;
    }
  }
}
