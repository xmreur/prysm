import 'package:flutter/widgets.dart';
import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/disappearing_timer_service.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/notification_mute_service.dart';
import 'package:prysm/services/pending_notification_route.dart';
import 'package:prysm/services/reaction_service.dart';
import 'package:prysm/services/read_receipt_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/services/wake_hint_service.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/disappearing_activity_notifier.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/inbound_message_notifier.dart';
import 'package:prysm/crypto/constants.dart';
import 'package:prysm/crypto/direct_message_auth.dart';
import 'package:prysm/crypto/envelope.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/peer_proof.dart';
import 'package:prysm/crypto/ratchet/prekey_bundle.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/notification_preview.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:prysm/util/peer_identity_loader.dart';

class InboundHandleResult {
  final int statusCode;
  final Map<String, dynamic>? jsonBody;
  final String? plainTextBody;

  const InboundHandleResult({
    required this.statusCode,
    this.jsonBody,
    this.plainTextBody,
  });

  static InboundHandleResult ok(Map<String, dynamic> body) =>
      InboundHandleResult(statusCode: 200, jsonBody: body);

  static InboundHandleResult badRequest(String message) =>
      InboundHandleResult(statusCode: 400, jsonBody: {'error': message});

  static InboundHandleResult forbidden(String message) =>
      InboundHandleResult(statusCode: 403, jsonBody: {'error': message});

  static InboundHandleResult internalError([
    String message = 'Processing failed',
  ]) => InboundHandleResult(statusCode: 500, jsonBody: {'error': message});
}

/// Shared inbound routing for HTTP and WebSocket transports.
class InboundMessageRouter {
  InboundMessageRouter({
    required this.keyManager,
    required this.settings,
    required this.localOnionAddress,
    this.fetchSenderProfile,
    this.resolvePeerIdentity,
  });

  final KeyManager keyManager;
  final SettingsService settings;
  final String? Function() localOnionAddress;
  final void Function(String senderId)? fetchSenderProfile;
  final Future<IdentityPublicKeys?> Function(String senderId)?
      resolvePeerIdentity;

  Future<InboundHandleResult> buildPublicKey() async {
    final body = await _publicIdentityBody();
    return InboundHandleResult(statusCode: 200, plainTextBody: body);
  }

  Future<InboundHandleResult> buildProfile({
    String? requesterOnion,
    bool requireRequester = false,
  }) async {
    if (_shouldRedactProfileForRequester(
      requesterOnion,
      requireRequester: requireRequester,
    )) {
      return InboundHandleResult.ok({
        'identityJson': '',
        'publicKeyPem': '',
        'username': '',
        'avatar': '',
      });
    }

    final broadcastName = settings.username;
    final username =
        (broadcastName != null &&
            broadcastName.isNotEmpty &&
            broadcastName != 'My Profile')
        ? broadcastName
        : '';
    final identityJson = await _publicIdentityBody();
    final body = <String, dynamic>{
      'identityJson': identityJson,
      'publicKeyPem': identityJson,
      'username': username,
      'avatar': settings.avatar ?? '',
      'ratchetScheme': CryptoConstants.schemeRatchet3,
    };
    if (keyManager.isUnlocked) {
      final bundle = await PrekeyBundle.loadStored(keyManager.identity);
      if (bundle != null) {
        body['prekeyBundle'] = bundle.toJson();
      }
    }
    return InboundHandleResult.ok(body);
  }

  Future<String> _publicIdentityBody() async {
    if (keyManager.isUnlocked) {
      return keyManager.publicKeyJson;
    }
    return await keyManager.storedPublicIdentityJson() ?? '';
  }

  Future<InboundHandleResult> handleSyncHint(Map<String, dynamic> data) async {
    final validationError = WakeHintService.validateSyncHintPayload(
      data,
      localOnionAddress(),
    );
    if (validationError != null) {
      return InboundHandleResult.badRequest(validationError);
    }

    final senderId = data['senderId'] as String;
    if (BlockService.instance.isBlocked(senderId)) {
      return InboundHandleResult.forbidden('Unknown sender');
    }

    final contact = await DBHelper.getUserById(senderId);
    if (contact == null) {
      return InboundHandleResult.forbidden('Unknown sender');
    }

    // The senderId claim must be proven: an attacker who learned one of our
    // contacts' onions could otherwise drive our outbound connections. Keep
    // the cheap checks (shape, block list, contact lookup) ahead of this so
    // an unauthenticated flood cannot force identity resolution.
    final peer = await _resolvePeerIdentity(senderId);
    final local = localOnionAddress();
    if (peer == null || local == null) {
      return InboundHandleResult.forbidden('Unknown sender');
    }
    final valid = await PeerProof.verify(
      context: PeerProof.syncHintContext,
      senderOnion: senderId,
      receiverOnion: local,
      timestampMs: data['timestamp'] as int,
      signature: data['sig'] as String,
      peer: peer,
    );
    if (!valid) {
      return InboundHandleResult.forbidden('Unknown sender');
    }

    unawaited(WakeHintService.instance.handleIncomingHint(senderId));
    return InboundHandleResult.ok({'status': 'ok'});
  }

  Future<InboundHandleResult> handleMessage(Map<String, dynamic> data) async {
    final validation = validateMessage(data);
    if (validation != null) return validation;
    return processMessage(data);
  }

  /// Sync validation only. Non-null means no async processing is required.
  InboundHandleResult? validateMessage(Map<String, dynamic> data) {
    final type = data['type'];
    if (type is! String) {
      return InboundHandleResult.badRequest('type required');
    }

    if (!_isValidMessageData(data)) {
      return InboundHandleResult.badRequest(
        'Missing required fields: id, senderId, receiverId, message, type, timestamp',
      );
    }

    if ([
          'file',
          'image',
          'audio',
          groupFileType,
          groupImageType,
          groupAudioType,
        ].contains(type) &&
        !_hasValidFileMetadata(data)) {
      return InboundHandleResult.badRequest(
        'File metadata required: fileName, fileSize',
      );
    }

    if (isGroupMessageType(type) && data['groupId'] == null) {
      return InboundHandleResult.badRequest(
        'groupId required for group messages',
      );
    }

    if (isGroupControlType(type)) {
      return _validateAddressedToLocal(data, controlMessage: true);
    }

    if (isMessageModifyType(type)) {
      if (type == groupMessageModifyType && data['groupId'] == null) {
        return InboundHandleResult.badRequest(
          'groupId required for group message modifies',
        );
      }
      return _validateAddressedToLocal(data);
    }

    if (isReadReceiptType(type)) {
      if ((type == groupReadReceiptType || type == groupReadWaterlineType) &&
          data['groupId'] == null) {
        return InboundHandleResult.badRequest(
          'groupId required for group read receipts',
        );
      }
      return _validateAddressedToLocal(data);
    }

    if (isReactionType(type)) {
      if (type == groupReactionType && data['groupId'] == null) {
        return InboundHandleResult.badRequest(
          'groupId required for group reactions',
        );
      }
      return _validateAddressedToLocal(data);
    }

    if (isDisappearingTimerType(type)) {
      return _validateAddressedToLocal(data);
    }

    return _validateAddressedToLocal(data);
  }

  /// Async processing after [validateMessage] returns null.
  Future<InboundHandleResult> processMessage(Map<String, dynamic> data) async {
    final senderId = '${data['senderId']}';
    Logging.info(
      'Received ${data['type']} from ${Logging.redactOnion(senderId)}',
      'InboundMessageRouter',
    );

    if (_isBlockedDm(data)) {
      return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
    }

    final type = data['type'] as String;

    if (isGroupControlType(type)) {
      return _handleGroupControl(data, type);
    }

    if (isMessageModifyType(type)) {
      return _handleMessageModify(data, type);
    }

    if (isReadReceiptType(type)) {
      return _handleReadReceipt(data, type);
    }

    if (isReactionType(type)) {
      return _handleReaction(data, type);
    }

    if (isDisappearingTimerType(type)) {
      return _handleDisappearingTimer(data);
    }

    return _handleChatMessage(data, type);
  }

  InboundHandleResult? _validateAddressedToLocal(
    Map<String, dynamic> data, {
    bool controlMessage = false,
  }) {
    final receiverId = data['receiverId'] as String;
    final senderId = data['senderId'] as String;
    final local = localOnionAddress();
    final id = data['id'];

    if (local != null) {
      if (senderId == local) {
        return InboundHandleResult.ok({'status': 'received', 'id': id});
      }
      if (receiverId != local) {
        return InboundHandleResult.forbidden(
          controlMessage
              ? 'Control message not addressed to this node'
              : 'Message not addressed to this node',
        );
      }
    }

    return null;
  }

  /// Optimistic ack body for fast WebSocket ack before async processing.
  Map<String, dynamic> optimisticAckBody(Map<String, dynamic> data) => {
    'status': 'received',
    'id': data['id'],
  };

  Future<InboundHandleResult> _handleGroupControl(
    Map<String, dynamic> data,
    String type,
  ) async {
    final receiverId = data['receiverId'] as String;
    final local = localOnionAddress();

    await DBHelper.ensureUserExist(data['senderId'] as String);

    final localId = local ?? receiverId;
    final groupService = GroupService(userId: localId, keyManager: keyManager);
    final bool handled;
    try {
      handled = await groupService.handleIncomingControlMessage(
        type,
        data['message'] as String,
        data['senderId'] as String,
      );
    } catch (e) {
      Logging.error('Group control handling failed: $e', 'InboundMessageRouter');
      return InboundHandleResult.internalError(
        'Group control processing failed',
      );
    }

    // M2 (security): the profile fetch is an implicit delivery receipt.
    // Fetch only after the control payload authenticated (signed
    // control-wrap-2 envelope); unauthenticated control traffic must not
    // reveal that we are online.
    if (handled) {
      fetchSenderProfile?.call(data['senderId'] as String);
    }

    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }

  Future<InboundHandleResult> _handleMessageModify(
    Map<String, dynamic> data,
    String type,
  ) async {
    final receiverId = data['receiverId'] as String;
    final senderId = data['senderId'] as String;
    final local = localOnionAddress();

    await DBHelper.ensureUserExist(senderId);

    final localId = local ?? receiverId;
    final groupService = GroupService(userId: localId, keyManager: keyManager);

    try {
      await MessageModifyService.applyInbound(
        keyManager: keyManager,
        encrypted: data['message'] as String,
        senderId: senderId,
        type: type,
        groupId: data['groupId'] as String?,
        groupService: groupService,
      );
    } catch (e) {
      Logging.error('Message modify handling failed: $e', 'InboundMessageRouter');
      return InboundHandleResult.internalError(
        'Message modify processing failed',
      );
    }

    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }

  Future<InboundHandleResult> _handleReadReceipt(
    Map<String, dynamic> data,
    String type,
  ) async {
    final receiverId = data['receiverId'] as String;
    final senderId = data['senderId'] as String;
    final local = localOnionAddress();

    await DBHelper.ensureUserExist(senderId);

    final localId = local ?? receiverId;
    final groupService = GroupService(userId: localId, keyManager: keyManager);

    try {
      await ReadReceiptService.applyInbound(
        keyManager: keyManager,
        encrypted: data['message'] as String,
        senderId: senderId,
        localUserId: localId,
        type: type,
        groupId: data['groupId'] as String?,
        groupService: groupService,
      );
    } catch (e) {
      Logging.error('Read receipt handling failed: $e', 'InboundMessageRouter');
      return InboundHandleResult.internalError(
        'Read receipt processing failed',
      );
    }

    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }

  Future<InboundHandleResult> _handleReaction(
    Map<String, dynamic> data,
    String type,
  ) async {
    final receiverId = data['receiverId'] as String;
    final senderId = data['senderId'] as String;
    final local = localOnionAddress();

    await DBHelper.ensureUserExist(senderId);

    final localId = local ?? receiverId;
    final groupService = GroupService(userId: localId, keyManager: keyManager);

    try {
      await ReactionService.applyInbound(
        keyManager: keyManager,
        encrypted: data['message'] as String,
        senderId: senderId,
        type: type,
        groupId: data['groupId'] as String?,
        groupService: groupService,
      );
    } catch (e) {
      Logging.error('Reaction handling failed: $e', 'InboundMessageRouter');
      return InboundHandleResult.internalError('Reaction processing failed');
    }

    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }

  Future<InboundHandleResult> _handleDisappearingTimer(
    Map<String, dynamic> data,
  ) async {
    final receiverId = data['receiverId'] as String;
    final senderId = data['senderId'] as String;
    final local = localOnionAddress();

    await DBHelper.ensureUserExist(senderId);

    final localId = local ?? receiverId;
    try {
      await DisappearingTimerService.applyInboundDirect(
        keyManager: keyManager,
        encrypted: data['message'] as String,
        senderId: senderId,
        localUserId: localId,
      );
    } catch (e) {
      Logging.error(
        'Disappearing timer handling failed: $e',
        'InboundMessageRouter',
      );
      return InboundHandleResult.internalError(
        'Disappearing timer processing failed',
      );
    }

    return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
  }

  Future<InboundHandleResult> _handleChatMessage(
    Map<String, dynamic> data,
    String type,
  ) async {
    final receiverId = data['receiverId'] as String;
    final senderId = data['senderId'] as String;
    final local = localOnionAddress();

    await DBHelper.ensureUserExist(senderId);

    final timeReceived = DateTime.now().millisecondsSinceEpoch;
    final incomingTimestamp = data['timestamp'];
    final messageTimestamp = incomingTimestamp is int && incomingTimestamp > 0
        ? incomingTimestamp
        : timeReceived;

    final inboundGroupId = data['groupId'] as String?;
    final localUserId = local;
    var messageStatus = (data['status'] as String?) ?? 'received';
    if (inboundGroupId != null && localUserId != null) {
      final joinedAt = await DBHelper.getMemberJoinedAt(
        inboundGroupId,
        localUserId,
      );
      if (joinedAt != null && messageTimestamp < joinedAt) {
        return InboundHandleResult.ok({'status': 'received', 'id': data['id']});
      }
    }

    if (inboundGroupId == null && isDirectMessageType(type)) {
      final auth = await DirectMessageAuth.authenticateInboundDirect(
        senderId: senderId,
        wire: data['message'] as String,
        type: type,
        localUserId: localUserId,
        keyManager: keyManager,
        resolveIdentity: _resolvePeerIdentity,
        fromNetwork: true,
        fullDecrypt: keyManager.isUnlocked,
      );
      switch (auth) {
        case DirectAuthOutcome.rejected:
          return InboundHandleResult.badRequest(
            'Invalid or unsigned direct message',
          );
        case DirectAuthOutcome.pendingAuth:
          messageStatus = 'pending_auth';
          // Explicit: pending-auth traffic never fetches the sender profile.
          // (A non-empty Dart case would not fall through anyway, but the
          // intent must not depend on that subtlety.)
          break;
        case DirectAuthOutcome.accepted:
          // M2 (security): only authenticated direct messages may trigger a
          // profile fetch. Fetching before auth leaked an implicit delivery
          // receipt (a GET /profile to the sender) for traffic that is
          // rejected or whose sender identity is unverified.
          fetchSenderProfile?.call(senderId);
          break;
      }
    }

    final localId = local ?? receiverId;
    if (inboundGroupId != null &&
        _isLegacyGroupAeadEnvelope(data)) {
      // The legacy group-aead envelope has no sender binding (iv/ct only):
      // any group member could craft a message attributed to another member.
      // Reject it at ingress; the display path still renders already-stored
      // legacy messages.
      return InboundHandleResult.badRequest(
        'Legacy group envelope scheme rejected: '
        '${CryptoConstants.schemeGroupAead1}',
      );
    }
    if (inboundGroupId != null &&
        await _isGroupSenderKeyReplay(data, inboundGroupId)) {
      // Exact-duplicate gate: the envelope's (senderId, index) was already
      // seen for this group, so this is a replay rather than a late
      // delivery. Idempotent ack, same shape as a successful delivery
      // (status, id, timestamp): a replayer cannot tell a drop from a
      // delivery. The seen-set is recorded BEFORE storage on first sight:
      // a soft-deleted tombstone wins over a re-delivery
      // (insertInboundMessage returns null for tombstoned ids), so an
      // envelope that was seen and deliberately not stored stays dropped.
      return InboundHandleResult.ok({
        'status': 'received',
        'id': data['id'],
        'timestamp': timeReceived,
      });
    }
    if (inboundGroupId != null) {
      // M2 (security): the profile fetch is an implicit delivery receipt and
      // must not be triggerable by traffic we cannot authenticate. The gates
      // above (pre-join, legacy scheme, anti-replay) are fail-open by design
      // for senders whose identity is not in the local user store: passing
      // them proves the envelope is new and storable, NOT that the sender is
      // authenticated. The fetch therefore fires only when the sender's
      // public identity is already known locally — a cache-only
      // loadPeerIdentityFromDb, never a Tor fetch. A group message from an
      // unknown sender is still accepted and stored exactly as before; only
      // the outbound GET /profile is suppressed, so no unauthenticated
      // traffic can confirm that we are online.
      final knownSender =
          await loadPeerIdentityFromDb(keyManager, senderId);
      if (knownSender != null) {
        fetchSenderProfile?.call(senderId);
      }
    }
    final conversationId = inboundGroupId ?? senderId;
    final expiresAt = await DisappearingTimerService.resolveInboundExpiresAt(
      data: data,
      conversationId: conversationId,
      messageTimestamp: messageTimestamp,
    );

    final inserted = await MessagesDb.insertInboundMessage({
      'id': data['id'] as String,
      'senderId': senderId,
      'receiverId': receiverId,
      'message': data['message'] as String,
      'type': type,
      if (data['groupId'] != null) 'groupId': data['groupId'] as String,
      if (data['fileName'] != null) 'fileName': data['fileName'] as String,
      if (data['fileSize'] != null) 'fileSize': data['fileSize'],
      'timestamp': messageTimestamp,
      'status': messageStatus,
      if (data['replyTo'] != null) 'replyTo': data['replyTo'],
      'viewOnce': (data['viewOnce'] == true || data['viewOnce'] == 1) ? 1 : 0,
      'expiresAt': ?expiresAt,
    }, localId);

    if (inserted != null && expiresAt != null) {
      DisappearingActivityNotifier.instance.notify();
    }

    if (inserted != null && inserted['status'] != 'pending_auth') {
      InboundMessageNotifier.instance.notify(
        InboundMessageEvent.fromRow(inserted),
      );
      ConversationRefreshNotifier.instance.notifyInboundMessage();
    }

    if (settings.enableNotifications &&
        inserted != null &&
        inserted['status'] != 'pending_auth') {
      final appState = WidgetsBinding.instance.lifecycleState;
      final isBackground =
          appState == AppLifecycleState.paused ||
          appState == AppLifecycleState.inactive ||
          appState == AppLifecycleState.detached;
      if (isBackground) {
        final groupId = data['groupId'] as String?;
        final isGroup = isGroupMessageType(type);
        final muteService = NotificationMuteService.instance;
        final muted = groupId != null
            ? muteService.isMuted(MuteTarget.group, groupId)
            : muteService.isMuted(MuteTarget.user, senderId);
        if (!muted) {
          final contact = await DBHelper.getUserById(senderId);
          final senderName =
              contact?['customName'] as String? ??
              contact?['name'] as String? ??
              'Unknown contact';
          final groupRow = groupId != null
              ? await DBHelper.getGroupById(groupId)
              : null;
          final groupName = groupRow?['name'] as String?;
          final viewOnce = data['viewOnce'] == true || data['viewOnce'] == 1;
          final title = notificationTitleForInbound(
            isGroup: isGroup,
            senderName: senderName,
            groupName: groupName,
          );
          final body = truncateNotificationBody(
            notificationBodyForInbound(
              type: type,
              isGroup: isGroup,
              senderName: senderName,
              viewOnce: viewOnce,
            ),
          );
          final route = PendingNotificationRoute(
            senderId: senderId,
            groupId: groupId,
            conversationType: isGroup ? 'group' : 'direct',
          );
          await NotificationService().showNewMessageNotification(
            title: title,
            message: body,
            notificationId: NotificationService.notificationIdFor(
              groupId: groupId,
              senderId: senderId,
            ),
            payload: route.toPayload(),
            androidGroupKey: groupId ?? senderId,
          );
        }
      }
    }

    return InboundHandleResult.ok({
      'status': 'received',
      'id': data['id'],
      'timestamp': timeReceived,
    });
  }

  /// Returns true when [data]'s `message` is a legacy group-aead envelope.
  ///
  /// The legacy scheme (`group-aead-1`) authenticates only the group key, not
  /// the sender, so it must be rejected at ingress. The sender-key scheme
  /// (and non-group traffic) is not affected.
  bool _isLegacyGroupAeadEnvelope(Map<String, dynamic> data) {
    final wire = data['message'];
    if (wire is! String) return false;
    final envelope = CryptoEnvelope.tryParse(wire);
    return envelope != null &&
        envelope['scheme'] == CryptoConstants.schemeGroupAead1;
  }

  /// Anti-replay gate for inbound group chat messages.
  ///
  /// The group sender-key envelope carries `senderId` and `index` in clear
  /// (they are used to derive the message key), so the router can authenticate
  /// and gate on them before decrypting. Returns true when the message must be
  /// acked-but-dropped:
  /// - the envelope can never decrypt (envelope senderId != transport
  ///   senderId; [GroupCryptoV2.decryptWithSenderKey] rejects the mismatch),
  ///   or
  /// - the envelope signature is valid and its exact (senderId, index) was
  ///   already seen from that sender in this group (exact-duplicate
  ///   detection: order-independent, so a late delivery of an unseen index
  ///   passes and an out-of-order retry is stored normally).
  ///
  /// Only envelopes with a valid Ed25519 signature record in the inbound
  /// seen-set: an unauthenticated peer must not be able to poison it for a
  /// legitimate sender. The sender is resolved cache-only
  /// ([loadPeerIdentityFromDb], never a Tor fetch): an unknown peer must not
  /// be able to force an awaited outbound fetch from this hot path. When the
  /// sender's public keys are unavailable, or the envelope is not a
  /// sender-key envelope (legacy group-aead traffic), the gate passes the
  /// message through untouched (pre-fix behavior).
  Future<bool> _isGroupSenderKeyReplay(
    Map<String, dynamic> data,
    String groupId,
  ) async {
    final wire = data['message'];
    if (wire is! String) return false;
    final envelope = CryptoEnvelope.tryParse(wire);
    if (envelope == null ||
        envelope['scheme'] != CryptoConstants.schemeGroupSender1) {
      return false;
    }
    final senderId = envelope['senderId'];
    final index = envelope['index'];
    if (senderId is! String || index is! int) return false;
    if (senderId != data['senderId']) {
      // Undecryptable junk by construction; storing it only archives noise.
      return true;
    }
    final peer = await loadPeerIdentityFromDb(keyManager, senderId);
    if (peer == null) return false;
    final ivB64 = envelope['iv'];
    final ctB64 = envelope['ct'];
    final sigRaw = envelope['sig'];
    if (ivB64 is! String || ctB64 is! String || sigRaw is! String) {
      return false;
    }
    // Mirror decryptWithSenderKey's signed payload byte-for-byte so the
    // router and the decrypt path can never disagree on authenticity.
    final signPayload = utf8.encode(
      '$groupId|$senderId|$index|$ivB64|$ctB64',
    );
    Signature signature;
    try {
      signature = Signature(base64Decode(sigRaw), publicKey: peer.signPublic);
    } catch (_) {
      return false;
    }
    if (!await IdentityKeyPair.verify(signPayload, signature)) {
      return false;
    }
    return !(await GroupSenderIndexStore.recordInboundIndex(
      groupId: groupId,
      senderId: senderId,
      index: index,
    ));
  }

  Future<IdentityPublicKeys?> _resolvePeerIdentity(String senderId) async {
    if (resolvePeerIdentity != null) {
      return resolvePeerIdentity!(senderId);
    }
    return loadPeerIdentityFromDb(keyManager, senderId);
  }

  bool _isValidMessageData(dynamic data) {
    return data is Map &&
        data['id'] is String &&
        data['senderId'] is String &&
        data['receiverId'] is String &&
        data['message'] is String &&
        data['type'] is String &&
        data['timestamp'] is int;
  }

  bool _hasValidFileMetadata(dynamic data) {
    return data['fileName'] is String && data['fileSize'] is int;
  }

  bool _isBlockedDm(Map<String, dynamic> data) {
    if (data['groupId'] != null) return false;
    return BlockService.instance.isBlocked(data['senderId'] as String);
  }

  bool _shouldRedactProfileForRequester(
    String? requesterOnion, {
    bool requireRequester = false,
  }) {
    if (requireRequester &&
        (requesterOnion == null || requesterOnion.isEmpty)) {
      return true;
    }
    if (requesterOnion != null &&
        requesterOnion.isNotEmpty &&
        BlockService.instance.isBlocked(requesterOnion)) {
      return true;
    }
    return false;
  }
}
