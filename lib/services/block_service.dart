import 'package:prysm/database/blocked_users_db.dart';
import 'package:prysm/services/call/call_manager.dart';

class BlockService {
  BlockService._();
  static final BlockService instance = BlockService._();

  final Set<String> _blockedIds = {};
  final Map<String, int> _blockedAt = {};

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
    await CallManager.endCallWithPeer(userId, reason: 'declined');
  }

  Future<void> unblock(String userId) async {
    if (!_blockedIds.contains(userId)) return;
    await BlockedUsersDb.unblock(userId);
    _blockedIds.remove(userId);
    _blockedAt.remove(userId);
  }
}
