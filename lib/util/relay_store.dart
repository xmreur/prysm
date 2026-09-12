import 'dart:convert';

import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';
import 'package:sqflite/sqflite.dart';

/// The deposit addresses this device handed out, one per contact.
///
/// The relay never learns which human an address belongs to: that mapping
/// lives here and nowhere else, which is exactly why revoking a contact is a
/// local delete plus one `mailbox delete` call.
class RelayMailboxStore {
  RelayMailboxStore._();

  static const String table = 'relay_mailboxes';

  static Future<void> ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS relay_mailboxes (
        peerId TEXT PRIMARY KEY,
        deposit TEXT NOT NULL,
        relayOnion TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_relay_mailboxes_deposit '
      'ON relay_mailboxes(deposit)',
    );
  }

  /// The address handed to [peerId] for [relayOnion], or null when the peer has
  /// none yet (or has one for a relay we are no longer paired with).
  static Future<String?> depositFor(String peerId, String relayOnion) async {
    final db = await DBHelper.database;
    final rows = await db.query(
      table,
      columns: ['deposit'],
      where: 'peerId = ? AND relayOnion = ?',
      whereArgs: [peerId, relayOnion],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['deposit'] as String?;
  }

  static Future<void> put({
    required String peerId,
    required String deposit,
    required String relayOnion,
  }) async {
    final db = await DBHelper.database;
    await db.insert(
      table,
      {
        'peerId': peerId,
        'deposit': deposit,
        'relayOnion': relayOnion,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Which contact a deposit address belongs to, for labelling in the UI.
  static Future<Map<String, String>> peersByDeposit() async {
    final db = await DBHelper.database;
    final rows = await db.query(table, columns: ['peerId', 'deposit']);
    return {
      for (final row in rows) row['deposit'] as String: row['peerId'] as String,
    };
  }

  static Future<void> removeByDeposit(String deposit) async {
    final db = await DBHelper.database;
    await db.delete(table, where: 'deposit = ?', whereArgs: [deposit]);
  }

  static Future<void> removeForPeer(String peerId) async {
    final db = await DBHelper.database;
    await db.delete(table, where: 'peerId = ?', whereArgs: [peerId]);
  }

  /// Called on unpair: the addresses are meaningless once the Contract is gone.
  static Future<void> clear() async {
    final db = await DBHelper.database;
    await db.delete(table);
  }
}

/// A peer's published [RelayAdvertisement], cached in `users.relayAdvertisement`.
///
/// Cached on purpose: the advertisement is needed precisely when the peer is
/// unreachable, so fetching it live would defeat the point. It stays
/// trustworthy because the owner signs it.
class PeerRelayStore {
  PeerRelayStore._();

  static const String column = 'relayAdvertisement';

  static Future<void> save(String peerId, Map<String, dynamic>? advert) async {
    try {
      final db = await DBHelper.database;
      await db.update(
        'users',
        {column: advert == null ? null : jsonEncode(advert)},
        where: 'id = ?',
        whereArgs: [peerId],
      );
    } catch (e) {
      Logging.error('Failed to cache relay advertisement: $e', 'PeerRelayStore');
    }
  }

  /// The cached advertisement, or null when absent or unparseable. A peer
  /// controls this JSON, so a bad value is ignored, never thrown on.
  static Future<RelayAdvertisement?> load(String peerId) async {
    try {
      final row = await DBHelper.getUserById(peerId);
      final raw = row?[column] as String?;
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return RelayAdvertisement.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  /// Extracts the `relay` block from a fetched `/profile` body, or null when it
  /// is absent or malformed.
  static Map<String, dynamic>? advertisementFromProfile(
    Map<String, dynamic> profile,
  ) {
    final raw = profile['relay'];
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    try {
      RelayAdvertisement.fromJson(map);
    } catch (_) {
      return null;
    }
    return map;
  }
}
