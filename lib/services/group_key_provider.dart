import 'dart:typed_data';

import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';

/// Caches and decrypts a user's group symmetric keys.
///
/// Extracted from [GroupService] (Fase 3.1): owns the in-memory
/// `{groupId: key}` / `{groupId: keyVersion}` caches and the DB lookup +
/// decrypt path, so both membership orchestration and the control channel
/// can resolve a group's current key without duplicating cache-invalidation
/// logic.
class GroupKeyProvider {
  final KeyManager keyManager;

  final Map<String, Uint8List> _cache = {};
  final Map<String, int> _versionCache = {};

  GroupKeyProvider({required this.keyManager});

  /// Drops the cached key for [groupId] (e.g. after a rotation or deletion).
  void invalidate(String groupId) {
    _cache.remove(groupId);
    _versionCache.remove(groupId);
  }

  /// Returns the decrypted group key for [groupId], or null if the group
  /// key is missing or fails to decrypt. Caches by key version so a stored
  /// key rotation (bumped `keyVersion`) is picked up automatically without
  /// requiring an explicit [invalidate] call.
  Future<Uint8List?> getDecryptedGroupKey(String groupId) async {
    try {
      final row = await DBHelper.getGroupKey(groupId);
      if (row == null) return null;
      final version = row['keyVersion'] as int? ?? 1;
      final cached = _cache[groupId];
      if (cached != null && _versionCache[groupId] == version) {
        return cached;
      }
      final key = await GroupCryptoV2.decryptGroupKey(
        row['encryptedKey'] as String,
        keyManager.identity,
      );
      _cache[groupId] = key;
      _versionCache[groupId] = version;
      return key;
    } catch (e) {
      Logging.error('Failed to decrypt group key for $groupId: $e', 'GroupKeyProvider');
      return null;
    }
  }
}
