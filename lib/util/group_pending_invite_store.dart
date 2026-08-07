import 'package:mutex/mutex.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite/sqflite.dart';

/// Group invites received from a sender whose identity is not in the local
/// user store, kept so the user can decide instead of losing them silently.
///
/// The stored [wire] is the raw `control-wrap-2` envelope and is NEVER
/// decrypted while pending: it is unauthenticated, attacker-controlled input,
/// so nothing from it may reach the UI or be parsed into the database. It is
/// only ever replayed through the normal authenticated path once the sender's
/// identity is locally known.
///
/// This table is written by unauthenticated traffic — `POST /message`
/// authenticates nobody and its only rate limit is keyed on the
/// sender-claimed `senderId` — so all three bounds below are load-bearing,
/// not tuning.
class GroupPendingInviteStore {
  GroupPendingInviteStore._();

  static final Mutex _mutex = Mutex();

  /// How many distinct senders may hold a pending invite at once.
  ///
  /// At capacity a NEW sender is refused rather than evicting the oldest
  /// row: eviction would let an attacker with cheap throwaway onions delete
  /// a genuine request, while refusal only degrades to the drop that was the
  /// accepted behaviour before this feature existed.
  static const int maxPendingSenders = 20;

  /// How long a pending invite survives without a decision. Bounds the table
  /// in time as well as in rows, so one filled by an attacker frees itself
  /// with no user action.
  static const Duration retention = Duration(days: 7);

  /// Longest held envelope, in UTF-16 code units — the envelope is base64
  /// and JSON, i.e. ASCII, so this equals its size in bytes, and checking
  /// `length` costs nothing on a payload whose whole point is being large.
  ///
  /// Same order as the `/sync-hint` body cap (InboundLimits.maxControlBodyBytes,
  /// 64 KiB): a real `control-wrap-2` invite envelope is a few kilobytes, so
  /// this rejects only abuse. It is load-bearing because the general inbound
  /// cap allows a body of up to 96 MiB, and 20 rows at that size would pin
  /// roughly 1.9 GB of attacker-chosen bytes for the whole retention window.
  static const int maxPendingWireChars = 64 * 1024;

  static Future<void> ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_pending_invites (
        senderId TEXT PRIMARY KEY,
        wire TEXT NOT NULL,
        receivedAt INTEGER NOT NULL
      )
    ''');
  }

  /// Keeps [wire] as the pending invite for [senderId], replacing any
  /// previous one from the same sender. Returns false when the global cap
  /// refuses a new sender or when [wire] exceeds [maxPendingWireChars]; the
  /// caller drops the invite exactly as it would with the feature off.
  static Future<bool> hold({
    required String senderId,
    required String wire,
  }) async {
    return _mutex.protect(() async {
      // Same refusal as the global cap below: a wire this large is not a
      // real invite envelope, and holding it would let unauthenticated
      // traffic pin attacker-chosen bytes for the retention window.
      if (wire.length > maxPendingWireChars) return false;
      final db = await DBHelper.database;
      await _pruneExpired(db);

      final existing = await db.query(
        'group_pending_invites',
        columns: ['senderId'],
        where: 'senderId = ?',
        whereArgs: [senderId],
        limit: 1,
      );
      if (existing.isEmpty && await _count(db) >= maxPendingSenders) {
        return false;
      }

      await db.insert(
        'group_pending_invites',
        {
          'senderId': senderId,
          'wire': wire,
          'receivedAt': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  /// Pending invites, newest first. Expired rows are pruned first, so a
  /// caller never sees a row it must filter itself.
  static Future<List<Map<String, Object?>>> pending() async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      await _pruneExpired(db);
      // rowid breaks a same-millisecond tie: two invites held inside the
      // same clock tick would otherwise come back in an arbitrary order.
      return db.query(
        'group_pending_invites',
        orderBy: 'receivedAt DESC, rowid DESC',
      );
    });
  }

  static Future<int> count() async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      await _pruneExpired(db);
      return _count(db);
    });
  }

  /// Returns the held envelope for [senderId] and deletes the row in the
  /// same critical section, so a second caller cannot replay it.
  static Future<String?> take(String senderId) async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      final rows = await db.query(
        'group_pending_invites',
        where: 'senderId = ?',
        whereArgs: [senderId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      await db.delete(
        'group_pending_invites',
        where: 'senderId = ?',
        whereArgs: [senderId],
      );
      return rows.first['wire'] as String?;
    });
  }

  static Future<void> discard(String senderId) async {
    await _mutex.protect(() async {
      final db = await DBHelper.database;
      await db.delete(
        'group_pending_invites',
        where: 'senderId = ?',
        whereArgs: [senderId],
      );
    });
  }

  /// Deletes every pending invite.
  ///
  /// Called when the user switches to `contactsOnly` mode: that mode
  /// promises nothing is stored, so whatever was held while the mode was
  /// `holdAsRequest` is discarded the moment the choice is made.
  static Future<void> clear() async {
    await _mutex.protect(() async {
      final db = await DBHelper.database;
      await db.delete('group_pending_invites');
    });
  }

  static Future<int> _count(Database db) async {
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM group_pending_invites'),
        ) ??
        0;
  }

  static Future<void> _pruneExpired(Database db) async {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - retention.inMilliseconds;
    await db.delete(
      'group_pending_invites',
      where: 'receivedAt < ?',
      whereArgs: [cutoff],
    );
  }
}
