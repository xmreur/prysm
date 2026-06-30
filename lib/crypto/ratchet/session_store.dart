import 'dart:convert';

import 'package:prysm/crypto/ratchet/ratchet_session.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Persists Double Ratchet session state per peer.
class RatchetSessionStore {
  RatchetSessionStore._();

  static Future<void> ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS session_state (
        peerId TEXT PRIMARY KEY,
        ratchetJson TEXT NOT NULL
      )
    ''');
  }

  static Future<RatchetSession?> load(String peerId) async {
    final db = await DBHelper.database;
    final rows = await db.query(
      'session_state',
      where: 'peerId = ?',
      whereArgs: [peerId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['ratchetJson'] as String?;
    if (raw == null || raw.isEmpty) return null;
    return RatchetSession.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  static Future<void> save(String peerId, RatchetSession session) async {
    final db = await DBHelper.database;
    await db.insert(
      'session_state',
      {
        'peerId': peerId,
        'ratchetJson': jsonEncode(session.toJson()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> delete(String peerId) async {
    final db = await DBHelper.database;
    await db.delete(
      'session_state',
      where: 'peerId = ?',
      whereArgs: [peerId],
    );
  }

  static Future<void> deleteAll() async {
    final db = await DBHelper.database;
    await db.delete('session_state');
  }
}
