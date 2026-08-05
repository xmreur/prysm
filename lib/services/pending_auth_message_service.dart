import 'package:prysm/crypto/direct_message_auth.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/peer_identity_resolver.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/inbound_message_notifier.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/peer_identity_loader.dart';

/// Promotes or quarantines direct messages received while the app was locked.
class PendingAuthMessageService {
  PendingAuthMessageService({
    required this.keyManager,
    Future<IdentityPublicKeys?> Function(String senderId)? resolvePeerIdentity,
  }) : _resolvePeerIdentity = resolvePeerIdentity;

  final KeyManager keyManager;
  final Future<IdentityPublicKeys?> Function(String senderId)?
      _resolvePeerIdentity;

  Future<void> promotePendingAfterUnlock({String? localUserId}) async {
    if (!keyManager.isUnlocked) return;

    final pending = await MessagesDb.getPendingAuthDirectMessages();
    if (pending.isEmpty) return;

    var promoted = false;
    for (final row in pending) {
      final senderId = row['senderId'] as String;
      final wire = row['message'] as String?;
      final type = row['type'] as String? ?? 'text';
      final messageId = row['id'] as String;
      if (wire == null || wire.isEmpty) {
        await MessagesDb.updateMessageStatus(messageId, 'quarantined');
        continue;
      }

      try {
        final auth = await DirectMessageAuth.authenticateInboundDirect(
          senderId: senderId,
          wire: wire,
          type: type,
          localUserId: localUserId,
          keyManager: keyManager,
          resolveIdentity: _resolveIdentity,
          fromNetwork: true,
          fullDecrypt: true,
        );
        if (auth == DirectAuthOutcome.accepted) {
          await MessagesDb.updateMessageStatus(messageId, 'received');
          final updated = {...row, 'status': 'received'};
          InboundMessageNotifier.instance.notify(
            InboundMessageEvent.fromRow(updated),
          );
          promoted = true;
        } else {
          await MessagesDb.updateMessageStatus(messageId, 'quarantined');
        }
      } catch (e, stack) {
        Logging.error(
          'Pending auth promotion failed for $messageId: $e\n$stack',
          'PendingAuthMessageService',
        );
        await MessagesDb.updateMessageStatus(messageId, 'quarantined');
      }
    }

    if (promoted) {
      ConversationRefreshNotifier.instance.notifyInboundMessage();
    }
  }

  Future<IdentityPublicKeys?> _resolveIdentity(String senderId) async {
    if (_resolvePeerIdentity != null) {
      return _resolvePeerIdentity(senderId);
    }
    final resolver = PeerIdentityResolver(
      peerId: senderId,
      keyManager: keyManager,
    );
    return resolvePeerIdentityForIngress(
      keyManager,
      senderId,
      fetchOverTor: () => resolver.fetchOverTor(),
    );
  }
}
