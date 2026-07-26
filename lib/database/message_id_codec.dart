/// Storage-id codec for the shared `messages` table.
///
/// Group messages are scoped per group (`groupId::wireId`) to avoid
/// cross-group primary-key collisions on REPLACE; direct messages use the
/// wire id unscoped.
class MessageIdCodec {
  MessageIdCodec._();

  /// Storage primary key: group messages are scoped per group to avoid cross-group REPLACE.
  static String scopedId({required String wireId, String? groupId}) {
    if (groupId != null && groupId.isNotEmpty) return '$groupId::$wireId';
    return wireId;
  }

  static String wireIdFromStorage(String storageId) {
    final sep = storageId.indexOf('::');
    if (sep < 0) return storageId;
    return storageId.substring(sep + 2);
  }
}
