import 'package:prysm/database/blocked_users_db.dart';

class BlockService {
  BlockService._();
  static final BlockService instance = BlockService._();

  final Set<String> _blockedIds = {};
  final Map<String, int> _blockedAt = {};

  /// Registered by the composition root (currently CallManager's wiring in
  /// main.dart) so BlockService doesn't need a compile-time dependency on
  /// the call subsystem. Breaks the BlockService <-> CallManager import
  /// cycle: CallManager still reads BlockService.instance.isBlocked
  /// directly (that edge stays, it's the fewer-call-site direction), but
  /// BlockService no longer calls back into CallManager statically.
  Future<void> Function(String userId)? onPeerBlocked;

  Future<void> init() async {
    _blockedIds.clear();
    _blockedAt.clear();
    final all = await BlockedUsersDb.getAll();
    for (final user in all) {
      _blockedIds.add(user.userId);
      _blockedAt[user.userId] = user.blockedAt;
    }
  }

  bool isBlocked(String userId) => _blockedIds.contains(userId);

  Set<String> get blockedIds => Set.unmodifiable(_blockedIds);

  int? blockedAt(String userId) => _blockedAt[userId];

  Future<void> block(String userId) async {
    if (_blockedIds.contains(userId)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await BlockedUsersDb.block(userId, now);
    _blockedIds.add(userId);
    _blockedAt[userId] = now;
    await onPeerBlocked?.call(userId);
  }

  Future<void> unblock(String userId) async {
    if (!_blockedIds.contains(userId)) return;
    await BlockedUsersDb.unblock(userId);
    _blockedIds.remove(userId);
    _blockedAt.remove(userId);
  }
}
