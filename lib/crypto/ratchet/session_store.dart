import 'dart:convert';

import 'package:prysm/crypto/ratchet/ratchet_session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Persists Double Ratchet session state per peer.
class RatchetSessionStore {
  RatchetSessionStore(this._db);

  final Database _db;

  static Future<void> ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS session_state (
        peerId TEXT PRIMARY KEY,
        ratchetJson TEXT NOT NULL
      )
    ''');
  }

  Future<RatchetSession?> load(String peerId) async {
    final rows = await _db.query(
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

  Future<void> save(String peerId, RatchetSession session) async {
    await _db.insert(
      'session_state',
      {
        'peerId': peerId,
        'ratchetJson': jsonEncode(session.toJson()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String peerId) async {
    await _db.delete(
      'session_state',
      where: 'peerId = ?',
      whereArgs: [peerId],
    );
  }

  Future<void> deleteAll() async {
    await _db.delete('session_state');
  }
}
