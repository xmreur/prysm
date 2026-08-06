import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tracks per-sender message index for group sender-key encryption.
class GroupSenderIndexStore {
  GroupSenderIndexStore._();

  static final Mutex _mutex = Mutex();

  /// Process-local ownership of unresolved inbound claims, keyed
  /// `'$groupId|$senderId|$index'` (onion ids and indices never contain
  /// `|`). A row in `group_inbound_seen` whose key is not in this set can
  /// only have been claimed by a previous process that died between claim
  /// and resolve: the next claim takes it over. There is deliberately no
  /// clock: an unresolved row was either claimed by *this* process (a live
  /// delivery owns it) or by a process that no longer exists (a crash) —
  /// that is a fact, not a timeout.
  static final Set<String> _liveClaims = <String>{};

  /// Clears process-local claim ownership. Required between test cases: the
  /// set is process-global, and the test suite runs many cases in one
  /// process, so a claim left by one case would refuse the same triple in
  /// the next. Mirrors the repo's resetForTest convention.
  @visibleForTesting
  static void resetForTest() {
    _liveClaims.clear();
  }

  static Future<void> ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_sender_index (
        groupId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        nextIndex INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (groupId, senderId)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_inbound_seen (
        groupId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        msgIndex INTEGER NOT NULL,
        resolved INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (groupId, senderId, msgIndex)
      )
    ''');
  }

  static Future<int> nextIndex({
    required String groupId,
    required String senderId,
  }) async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      final rows = await db.query(
        'group_sender_index',
        where: 'groupId = ? AND senderId = ?',
        whereArgs: [groupId, senderId],
        limit: 1,
      );
      final current = rows.isEmpty ? 0 : rows.first['nextIndex'] as int;
      final next = current + 1;
      await db.insert(
        'group_sender_index',
        {
          'groupId': groupId,
          'senderId': senderId,
          'nextIndex': next,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return current;
    });
  }

  /// Claims the inbound (groupId, senderId, index) triple before the message
  /// is stored.
  ///
  /// Two-phase anti-replay: the claim marks the triple as in-flight. The
  /// caller must later [resolveInboundIndex] once the envelope reached a
  /// terminal decision (stored, or deliberately dropped by the storage
  /// layer), or [releaseInboundIndex] when storage failed — otherwise a
  /// failed or crashed store would turn the sender's retry into a permanent
  /// loss.
  ///
  /// Returns true when the caller owns the claim and must proceed:
  /// - the triple was never seen before, or
  /// - an unresolved row was left by a previous process (a crash between
  ///   claim and resolve): this process takes the claim over. There is no
  ///   expiry window — the sender's retry is processed whenever it arrives.
  /// Returns false when the triple is a duplicate: it was already resolved,
  /// or an unresolved claim is still owned by this process — a concurrent
  /// delivery of the same envelope is being processed right now, and
  /// dropping it keeps the guarantee that two copies of the same envelope
  /// cannot both be stored.
  ///
  /// This is a read-modify-write, so it runs inside [_mutex] — unlike the
  /// single-statement `INSERT OR IGNORE` it replaced, which was atomic on
  /// its own.
  static Future<bool> claimInboundIndex({
    required String groupId,
    required String senderId,
    required int index,
  }) async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      final inserted = await db.insert(
        'group_inbound_seen',
        {
          'groupId': groupId,
          'senderId': senderId,
          'msgIndex': index,
          'resolved': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (inserted != 0) {
        _liveClaims.add('$groupId|$senderId|$index');
        return true;
      }

      final rows = await db.query(
        'group_inbound_seen',
        where: 'groupId = ? AND senderId = ? AND msgIndex = ?',
        whereArgs: [groupId, senderId, index],
        limit: 1,
      );
      final row = rows.first;
      if (row['resolved'] == 1) return false;
      if (_liveClaims.contains('$groupId|$senderId|$index')) {
        // A concurrent delivery of the same envelope is in flight in this
        // process: refusing it keeps two copies from both being stored.
        return false;
      }
      // The row was left by a previous process that died between claim and
      // resolve: take the claim over.
      _liveClaims.add('$groupId|$senderId|$index');
      return true;
    });
  }

  /// Marks the claimed triple as resolved: a terminal decision was reached
  /// for the envelope (stored, or deliberately dropped by the storage layer
  /// — e.g. a soft-delete tombstone). A resolved triple is a duplicate
  /// forever.
  static Future<void> resolveInboundIndex({
    required String groupId,
    required String senderId,
    required int index,
  }) async {
    await _mutex.protect(() async {
      final db = await DBHelper.database;
      await db.update(
        'group_inbound_seen',
        {'resolved': 1},
        where: 'groupId = ? AND senderId = ? AND msgIndex = ?',
        whereArgs: [groupId, senderId, index],
      );
      _liveClaims.remove('$groupId|$senderId|$index');
    });
  }

  /// Releases the claim after a failed ingress so the sender's retry can
  /// claim the triple again. Only removes an unresolved row: a resolved row
  /// must never be removed by a later failure.
  static Future<void> releaseInboundIndex({
    required String groupId,
    required String senderId,
    required int index,
  }) async {
    await _mutex.protect(() async {
      try {
        final db = await DBHelper.database;
        await db.delete(
          'group_inbound_seen',
          where: 'groupId = ? AND senderId = ? AND msgIndex = ? AND resolved = 0',
          whereArgs: [groupId, senderId, index],
        );
      } finally {
        // The key must go even if the delete fails: a surviving key would
        // refuse the sender's retry for the rest of the process lifetime.
        // [resolveInboundIndex] deliberately does NOT do this — if its
        // update fails the message is already stored, so keeping the key
        // (and refusing re-deliveries) is the safe outcome there.
        _liveClaims.remove('$groupId|$senderId|$index');
      }
    });
  }

  static Future<void> resetForGroup(String groupId) async {
    await _mutex.protect(() async {
      final db = await DBHelper.database;
      await db.delete(
        'group_sender_index',
        where: 'groupId = ?',
        whereArgs: [groupId],
      );
      await db.delete(
        'group_inbound_seen',
        where: 'groupId = ?',
        whereArgs: [groupId],
      );
      // Drop every in-memory key belonging to the group too: a stale key
      // must not outlive the rows it describes. If another process later
      // crashes mid-claim on one of these triples, its unresolved row must
      // be taken over — a stale key from before the reset would refuse it.
      _liveClaims.removeWhere((key) => key.startsWith('$groupId|'));
    });
  }
}
