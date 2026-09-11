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
    for (final name in [
      'chat_app.db',
      'messages.db',
      'pending_messages.db',
    ]) {
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

  /// Wipe for account transfer: [wipeAll] plus the hidden-service keys, so
  /// the source cannot come back online with the transferred onion. Desktop
  /// deletes the Tor hidden-service dir; mobile clears it through the
  /// native channel. Runs after the transfer backup is safely written.
  /// Returns true only when the HS keys are confirmed gone: the caller must
  /// NOT report transfer success on false (double-onion risk).
  static Future<bool> wipeForTransfer({dynamic torManager}) async {
    await wipeAll();
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // Mobile keys live behind the native channel; without a manager
        // there is nothing Dart-side to delete and removal is unconfirmed.
        if (torManager == null) return false;
        return await torManager.clearHsKeysForTransfer() == true;
      }
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
