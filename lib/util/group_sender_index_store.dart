import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tracks per-sender message index for group sender-key encryption.
class GroupSenderIndexStore {
  GroupSenderIndexStore._();

  static final Mutex _mutex = Mutex();

  /// How many resolved inbound indices are kept per (groupId, senderId)
  /// before the oldest are pruned into [group_inbound_floor]'s rejecting
  /// floor.
  ///
  /// Retention trade-off: one `group_inbound_seen` row is ~56 bytes, so a
  /// pair costs at most ~14 KB and a 20-member group at most ~280 KB. The
  /// retained window is what bounds out-of-order tolerance — an index is
  /// accepted out of order only while its row still exists. The retry path
  /// exercises only a handful of messages deep (`group_chat_service.dart`
  /// re-sends the stored envelope with its original index), so 256 is far
  /// beyond any live out-of-order demand while keeping the table flat.
  static const int _seenRetained = 256;

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
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_inbound_floor (
        groupId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        prunedBelow INTEGER NOT NULL,
        PRIMARY KEY (groupId, senderId)
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
  ///   expiry window — the sender's retry is processed whenever it arrives,
  ///   unless the pair has meanwhile churned past the index and the floor
  ///   below has moved over it.
  /// Returns false when the triple is a duplicate: it was already resolved,
  /// an unresolved claim is still owned by this process — a concurrent
  /// delivery of the same envelope is being processed right now, and
  /// dropping it keeps the guarantee that two copies of the same envelope
  /// cannot both be stored — or the index lies below the pair's pruning
  /// floor ([group_inbound_floor]).
  ///
  /// The floor refusal is not a return of the original high-water mark. It
  /// is raised only by pruning rows that were seen and resolved, never by
  /// the *value* of an incoming index, so a relayed high index cannot push
  /// it — that was the vulnerability in the original watermark. What it
  /// refuses is an index that was pruned, or one that falls in a gap the
  /// floor has passed over (an index never delivered while [_seenRetained]
  /// later ones were): bounded staleness, not attacker-controlled.
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
      // Everything at or below the floor was seen, resolved and pruned, so
      // a claim there is a replay of an already-delivered message. Reading
      // it first keeps the row count bounded from the claim side as well.
      final floors = await db.query(
        'group_inbound_floor',
        where: 'groupId = ? AND senderId = ?',
        whereArgs: [groupId, senderId],
        limit: 1,
      );
      if (floors.isNotEmpty &&
          index < (floors.first['prunedBelow'] as int)) {
        return false;
      }

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
      // Enforce the retention bound now that the row is terminal; the
      // common path inside stays a single cheap count query.
      await _prune(db, groupId, senderId);
    });
  }

  /// Enforces the per-(groupId, senderId) retention bound after a resolve.
  ///
  /// Counts the pair's resolved rows and does nothing while the count is
  /// within [_seenRetained] — the common path is one cheap query. When the
  /// count exceeds the bound, the oldest `count - _seenRetained` resolved
  /// rows are deleted and [group_inbound_floor] is raised to
  /// `max(existing, highest deleted index + 1)`: everything below the floor
  /// was seen, resolved and removed, so a later claim at or below it is a
  /// replay of an already-delivered message and must be refused, never
  /// re-accepted.
  ///
  /// An unresolved row is never pruned: it is a claim in flight or a
  /// crashed claim that must stay recoverable — deleting it would turn the
  /// sender's retry into a permanent loss instead of a delivery. The floor
  /// can pass over such a row (pruning deletes only resolved rows), and
  /// the row itself survives, so it stays releasable and resolvable; but a
  /// retry that arrives only after the pair has churned past its index is
  /// refused at or below the floor rather than delivered. The bounded
  /// table, not the stale retry, wins — the retention bound is a hard
  /// limit, and the live retry path never goes that deep
  /// ([_seenRetained] is far beyond the retry machinery's reach).
  static Future<void> _prune(
    Database db,
    String groupId,
    String senderId,
  ) async {
    final countRows = await db.rawQuery(
      'SELECT COUNT(*) FROM group_inbound_seen '
      'WHERE groupId = ? AND senderId = ? AND resolved = 1',
      [groupId, senderId],
    );
    final count = countRows.first.values.first as int;
    if (count <= _seenRetained) return;

    final excess = count - _seenRetained;
    final oldest = await db.rawQuery(
      'SELECT msgIndex FROM group_inbound_seen '
      'WHERE groupId = ? AND senderId = ? AND resolved = 1 '
      'ORDER BY msgIndex ASC LIMIT ?',
      [groupId, senderId, excess],
    );
    // `oldest` holds the lowest `excess` resolved rows, so the highest of
    // them marks the whole deletion window: every resolved row at or below
    // it is one of them, and every unresolved row in between is skipped by
    // the `resolved = 1` predicate.
    final highestDeleted = oldest.last['msgIndex'] as int;
    await db.delete(
      'group_inbound_seen',
      where: 'groupId = ? AND senderId = ? AND resolved = 1 AND msgIndex <= ?',
      whereArgs: [groupId, senderId, highestDeleted],
    );

    final newFloor = highestDeleted + 1;
    final floors = await db.query(
      'group_inbound_floor',
      where: 'groupId = ? AND senderId = ?',
      whereArgs: [groupId, senderId],
      limit: 1,
    );
    final existing = floors.isEmpty ? 0 : floors.first['prunedBelow'] as int;
    if (newFloor > existing) {
      await db.insert(
        'group_inbound_floor',
        {
          'groupId': groupId,
          'senderId': senderId,
          'prunedBelow': newFloor,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
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
      await db.delete(
        'group_inbound_floor',
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
