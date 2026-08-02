import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/models/disappearing_timer.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/pending_side_channel_queue.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/services/side_channel_transport.dart';
import 'package:prysm/transport/transport_provider.dart';
import 'package:prysm/util/disappearing_activity_notifier.dart';
import 'package:prysm/util/disappearing_timer_refresh_notifier.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/peer_identity_loader.dart';
import 'package:uuid/uuid.dart';

class DisappearingTimerPayload {
  const DisappearingTimerPayload({
    required this.timerSeconds,
    required this.updatedAt,
    this.updatedBy,
  });

  final int? timerSeconds;
  final int updatedAt;
  final String? updatedBy;

  Map<String, dynamic> toJson() => {
        'timerSeconds': timerSeconds,
        'updatedAt': updatedAt,
        if (updatedBy != null) 'updatedBy': updatedBy,
      };

  factory DisappearingTimerPayload.fromJson(Map<String, dynamic> json) {
    final raw = json['timerSeconds'];
    int? seconds;
    if (raw is int) {
      seconds = raw > 0 ? raw : null;
    }
    return DisappearingTimerPayload(
      timerSeconds: seconds,
      updatedAt: json['updatedAt'] as int? ??
          DateTime.now().millisecondsSinceEpoch,
      updatedBy: json['updatedBy'] as String?,
    );
  }

  String encode() => jsonEncode(toJson());

  static DisappearingTimerPayload decode(String plaintext) =>
      DisappearingTimerPayload.fromJson(
        jsonDecode(plaintext) as Map<String, dynamic>,
      );
}

/// Per-conversation disappearing-message timer: local persistence, wire sync,
/// and expiry computation for outbound/inbound chat messages.
class DisappearingTimerService {
  DisappearingTimerService({
    required this.userId,
    required this.keyManager,
    SideChannelTransport? transport,
  }) : _transport = transport;

  final String userId;
  final KeyManager keyManager;
  final SideChannelTransport? _transport;

  static final Map<String, SideChannelTransport> _sharedTransports = {};
  static SideChannelTransport? _testTransport;

  @visibleForTesting
  static void configure({SideChannelTransport? transport}) {
    _testTransport = transport;
  }

  @visibleForTesting
  static void resetForTest() {
    _testTransport = null;
    _sharedTransports.clear();
  }

  static SideChannelTransport _transportFor(String userId) =>
      _testTransport ??
      _sharedTransports.putIfAbsent(
        userId,
        () => SideChannelTransport(
          userId: userId,
          outbox: const PendingSideChannelQueue(),
          postman: const _DisappearingTimerPostman(),
          maxAttempts: 3,
          onDeliveryError: (context, error) => Logging.error(
            'Disappearing timer delivery failed: $error',
            'DisappearingTimerService',
          ),
        ),
      );

  SideChannelTransport get _directTransport =>
      _transport ?? _transportFor(userId);

  static String eventId({
    required String conversationId,
    required int updatedAt,
  }) =>
      'disappearing_timer::$conversationId::$updatedAt';

  static Future<int?> getTimerSeconds(String conversationId) async {
    final prefs = await ConversationPreferencesDb.get(conversationId);
    final seconds = prefs?.disappearingTimerSeconds;
    if (seconds == null || seconds <= 0) return null;
    return seconds;
  }

  static Future<int?> expiresAtForSend(
    String conversationId, {
    DateTime? at,
  }) async {
    final seconds = await getTimerSeconds(conversationId);
    if (seconds == null) return null;
    final base = at ?? DateTime.now();
    return base.add(Duration(seconds: seconds)).millisecondsSinceEpoch;
  }

  static Future<int?> resolveInboundExpiresAt({
    required Map<String, dynamic> data,
    required String conversationId,
    required int messageTimestamp,
  }) async {
    final wire = data['expiresAt'];
    if (wire is int && wire > 0) return wire;
    return expiresAtForSend(
      conversationId,
      at: DateTime.fromMillisecondsSinceEpoch(messageTimestamp),
    );
  }

  Future<void> setDirectTimer({
    required String peerId,
    required int? timerSeconds,
  }) async {
    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _persistTimer(peerId, timerSeconds, updatedAt: updatedAt);
    await _insertTimerNotice(
      conversationId: peerId,
      peerId: peerId,
      timerSeconds: timerSeconds,
      actorId: userId,
      updatedAt: updatedAt,
    );
    await _broadcastDirect(peerId: peerId, timerSeconds: timerSeconds, updatedAt: updatedAt);
  }

  Future<void> setGroupTimer({
    required String groupId,
    required List<String> memberIds,
    required int? timerSeconds,
    GroupService? groupService,
  }) async {
    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _persistTimer(groupId, timerSeconds, updatedAt: updatedAt);
    await _insertTimerNotice(
      conversationId: groupId,
      groupId: groupId,
      timerSeconds: timerSeconds,
      actorId: userId,
      updatedAt: updatedAt,
    );
    if (groupService != null) {
      await groupService.syncDisappearingTimer(
        groupId: groupId,
        memberIds: memberIds,
        timerSeconds: timerSeconds,
        updatedAt: updatedAt,
      );
    }
  }

  Future<void> _persistTimer(
    String conversationId,
    int? timerSeconds, {
    required int updatedAt,
  }) async {
    final existing = await ConversationPreferencesDb.get(conversationId);
    final normalized = timerSeconds != null && timerSeconds > 0
        ? timerSeconds
        : null;
    await ConversationPreferencesDb.upsert(
      (existing ??
              ConversationPreferences(conversationId: conversationId))
          .copyWith(
        disappearingTimerSeconds: normalized,
        clearDisappearingTimer: normalized == null,
      ),
    );
    DisappearingTimerRefreshNotifier.instance.notify(conversationId);
    DisappearingActivityNotifier.instance.notify();
    if (kDebugMode) {
      Logging.debug(
        'Disappearing timer for $conversationId -> '
        '${DisappearingTimerPresets.labelForSeconds(normalized)} '
        '(updatedAt=$updatedAt)',
        'DisappearingTimerService',
      );
    }
  }

  Future<void> _broadcastDirect({
    required String peerId,
    required int? timerSeconds,
    required int updatedAt,
  }) async {
    final peerKey = await loadPeerIdentityFromDb(keyManager, peerId);
    if (peerKey == null) return;

    final payload = DisappearingTimerPayload(
      timerSeconds: timerSeconds,
      updatedAt: updatedAt,
      updatedBy: userId,
    );
    final encrypted = await keyManager.encryptForPeer(
      payload.encode(),
      peerKey,
      peerId: peerId,
    );
    await _directTransport.sendDirectAndQueue(
      id: eventId(conversationId: peerId, updatedAt: updatedAt),
      peerId: peerId,
      encrypted: encrypted,
      timestamp: updatedAt,
      type: disappearingTimerType,
    );
  }

  static Future<void> applyInboundDirect({
    required KeyManager keyManager,
    required String encrypted,
    required String senderId,
    required String localUserId,
  }) async {
    final peerKey = await loadPeerIdentityFromDb(keyManager, senderId);
    if (peerKey == null) return;

    final plaintext = await keyManager.decryptPeerMessage(
      peerId: senderId,
      wire: encrypted,
      peer: peerKey,
    );
    final payload = DisappearingTimerPayload.decode(plaintext);
    final conversationId = senderId;
    final applied = await _applyInboundIfNewer(
      conversationId: conversationId,
      payload: payload,
    );
    if (!applied) return;
    await _insertTimerNotice(
      conversationId: conversationId,
      peerId: conversationId,
      timerSeconds: payload.timerSeconds,
      actorId: payload.updatedBy ?? senderId,
      updatedAt: payload.updatedAt,
      localUserId: localUserId,
    );
  }

  static Future<void> applyInboundGroup({
    required String groupId,
    required DisappearingTimerPayload payload,
    required String localUserId,
  }) async {
    final applied = await _applyInboundIfNewer(
      conversationId: groupId,
      payload: payload,
    );
    if (!applied) return;
    await _insertTimerNotice(
      conversationId: groupId,
      groupId: groupId,
      timerSeconds: payload.timerSeconds,
      actorId: payload.updatedBy ?? localUserId,
      updatedAt: payload.updatedAt,
      localUserId: localUserId,
    );
  }

  static Future<bool> _applyInboundIfNewer({
    required String conversationId,
    required DisappearingTimerPayload payload,
  }) async {
    final existing = await ConversationPreferencesDb.get(conversationId);
    // Last-write-wins on updatedAt when we have no stored timestamp yet.
    final normalized = payload.timerSeconds != null && payload.timerSeconds! > 0
        ? payload.timerSeconds
        : null;
    await ConversationPreferencesDb.upsert(
      (existing ??
              ConversationPreferences(conversationId: conversationId))
          .copyWith(
        disappearingTimerSeconds: normalized,
        clearDisappearingTimer: normalized == null,
      ),
    );
    DisappearingTimerRefreshNotifier.instance.notify(conversationId);
    DisappearingActivityNotifier.instance.notify();
    return true;
  }

  static Future<void> _insertTimerNotice({
    required String conversationId,
    required int? timerSeconds,
    required String actorId,
    required int updatedAt,
    String? peerId,
    String? groupId,
    String? localUserId,
  }) async {
    final local = localUserId ?? actorId;
    final receiverId = groupId != null ? local : (peerId ?? conversationId);
    try {
      await MessagesDb.insertMessage({
        'id': const Uuid().v4(),
        'senderId': actorId,
        'receiverId': receiverId,
        if (groupId != null) 'groupId': groupId,
        'message': jsonEncode({
          'timerSeconds': timerSeconds,
          'actorId': actorId,
        }),
        'type': disappearingTimerNoticeType,
        'timestamp': updatedAt,
        'status': 'system',
      });
    } catch (e) {
      Logging.error(
        'Failed to insert disappearing timer notice: $e',
        'DisappearingTimerService',
      );
    }
  }
}

class _DisappearingTimerPostman implements SideChannelPostman {
  const _DisappearingTimerPostman();

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await TransportProvider.postMessageOrFallback(
      peerOnion: peerId,
      payload: payload,
      timeout: timeout,
    );
  }

  @override
  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await TransportProvider.postMessageOrFallback(
      peerOnion: targetMemberId,
      payload: payload,
      timeout: timeout,
    );
  }
}
