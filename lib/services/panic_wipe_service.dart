import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/panic_pin_service.dart';
import 'package:prysm/util/db_helper.dart';
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
      final file = File(p.join(prysmDir.path, name));
      if (await file.exists()) {
        await file.delete();
      }
    }

    const secureStorage = FlutterSecureStorage();
    await secureStorage.deleteAll();
    await PanicPinService.instance.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}
