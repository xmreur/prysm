import 'contract.dart';
import 'errors.dart';
import 'limits.dart';
import 'protocol.dart';
import 'seal.dart';
import 'signing.dart';

/// `POST /relay/deposit` — authorised by knowledge of [deposit] alone. The
/// sender never identifies itself and never signs.
class RelayDepositRequest {
  final String deposit;
  final Map<String, dynamic> payload;

  const RelayDepositRequest({required this.deposit, required this.payload});

  Map<String, dynamic> toJson() => {
        'protocol': RelayProtocol.id,
        'deposit': deposit,
        'payload': payload,
      };

  static RelayDepositRequest fromJson(Map<String, dynamic> json) {
    RelayFields.requireProtocol(json['protocol']);
    final payload = RelayFields.object(json['payload'], field: 'payload');
    if (!RelaySeal.isSealed(payload)) {
      throw RelayError.badRequest(
        'payload must be a ${RelayProtocol.sealScheme} envelope',
      );
    }
    return RelayDepositRequest(
      deposit: RelayFields.depositAddress(json['deposit']),
      payload: payload,
    );
  }
}

class RelayDepositResponse {
  final String itemId;
  final int expiresAt;

  const RelayDepositResponse({required this.itemId, required this.expiresAt});

  Map<String, dynamic> toJson() => {
        'status': 'stored',
        'itemId': itemId,
        'expiresAt': expiresAt,
      };

  static RelayDepositResponse fromJson(Map<String, dynamic> json) =>
      RelayDepositResponse(
        itemId: RelayFields.text(json['itemId'], field: 'itemId', maxBytes: 64),
        expiresAt: RelayFields.timestamp(json['expiresAt'], field: 'expiresAt'),
      );
}

/// One stored blob, as handed back by `POST /relay/pickup`.
class RelayItem {
  final String itemId;
  final String deposit;
  final int storedAt;
  final int expiresAt;
  final int size;
  final Map<String, dynamic> payload;

  const RelayItem({
    required this.itemId,
    required this.deposit,
    required this.storedAt,
    required this.expiresAt,
    required this.size,
    required this.payload,
  });

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'deposit': deposit,
        'storedAt': storedAt,
        'expiresAt': expiresAt,
        'size': size,
        'payload': payload,
      };

  static RelayItem fromJson(Map<String, dynamic> json) {
    final size = json['size'];
    return RelayItem(
      itemId: RelayFields.text(json['itemId'], field: 'itemId', maxBytes: 64),
      deposit: RelayFields.depositAddress(json['deposit']),
      storedAt: RelayFields.timestamp(json['storedAt'], field: 'storedAt'),
      expiresAt: RelayFields.timestamp(json['expiresAt'], field: 'expiresAt'),
      size: size is int && size >= 0 ? size : 0,
      payload: RelayFields.object(json['payload'], field: 'payload'),
    );
  }
}

class RelayPickupRequest {
  final int? max;

  const RelayPickupRequest({this.max});

  Map<String, dynamic> toJson() => {
        'protocol': RelayProtocol.id,
        if (max != null) 'max': max,
      };

  static RelayPickupRequest fromJson(Map<String, dynamic> json) {
    RelayFields.requireProtocol(json['protocol']);
    final max = json['max'];
    return RelayPickupRequest(max: max is int && max > 0 ? max : null);
  }
}

class RelayPickupResponse {
  final List<RelayItem> items;
  final bool more;
  final RelayUsage usage;

  const RelayPickupResponse({
    required this.items,
    required this.more,
    required this.usage,
  });

  Map<String, dynamic> toJson() => {
        'items': items.map((i) => i.toJson()).toList(),
        'more': more,
        'usage': usage.toJson(),
      };

  static RelayPickupResponse fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    if (raw is! List) {
      throw RelayError.badRequest('items must be a list');
    }
    return RelayPickupResponse(
      items: raw
          .map((e) => RelayItem.fromJson(
                RelayFields.object(e, field: 'items[]'),
              ))
          .toList(),
      more: json['more'] == true,
      usage: RelayUsage.fromJson(
        RelayFields.object(json['usage'], field: 'usage'),
      ),
    );
  }
}

/// `POST /relay/ack` — pickup is non-destructive, so this is what actually
/// frees the mailbox. A client that dies mid-pickup loses nothing.
class RelayAckRequest {
  final List<String> itemIds;

  const RelayAckRequest(this.itemIds);

  Map<String, dynamic> toJson() => {
        'protocol': RelayProtocol.id,
        'itemIds': itemIds,
      };

  static RelayAckRequest fromJson(Map<String, dynamic> json) {
    RelayFields.requireProtocol(json['protocol']);
    final raw = json['itemIds'];
    if (raw is! List) {
      throw RelayError.badRequest('itemIds must be a list');
    }
    return RelayAckRequest(
      raw
          .map((e) => RelayFields.text(e, field: 'itemIds[]', maxBytes: 64))
          .toList(),
    );
  }
}

class RelayAckResponse {
  final int deleted;
  final int unknown;

  const RelayAckResponse({required this.deleted, required this.unknown});

  Map<String, dynamic> toJson() => {'deleted': deleted, 'unknown': unknown};

  static RelayAckResponse fromJson(Map<String, dynamic> json) => RelayAckResponse(
        deleted: json['deleted'] is int ? json['deleted'] as int : 0,
        unknown: json['unknown'] is int ? json['unknown'] as int : 0,
      );
}

enum RelayMailboxOp {
  put,
  disable,
  delete,
  list;

  static RelayMailboxOp parse(Object? raw) => switch (raw) {
        'put' => RelayMailboxOp.put,
        'disable' => RelayMailboxOp.disable,
        'delete' => RelayMailboxOp.delete,
        'list' => RelayMailboxOp.list,
        _ => throw RelayError.badRequest('unknown mailbox op: $raw'),
      };

  String get wire => name;
}

/// `POST /relay/mailbox` — the owner registers, suspends or revokes a deposit
/// address. The set of registered addresses *is* the whitelist.
class RelayMailboxCommand {
  final RelayMailboxOp op;
  final String? deposit;
  final String? label;
  final int? maxItems;
  final int? maxBytes;

  const RelayMailboxCommand({
    required this.op,
    this.deposit,
    this.label,
    this.maxItems,
    this.maxBytes,
  });

  Map<String, dynamic> toJson() => {
        'protocol': RelayProtocol.id,
        'op': op.wire,
        if (deposit != null) 'deposit': deposit,
        if (label != null) 'label': label,
        if (maxItems != null) 'maxItems': maxItems,
        if (maxBytes != null) 'maxBytes': maxBytes,
      };

  static RelayMailboxCommand fromJson(Map<String, dynamic> json) {
    RelayFields.requireProtocol(json['protocol']);
    final op = RelayMailboxOp.parse(json['op']);
    final needsAddress = op != RelayMailboxOp.list;
    final label = json['label'];
    final maxItems = json['maxItems'];
    final maxBytes = json['maxBytes'];
    return RelayMailboxCommand(
      op: op,
      deposit: needsAddress ? RelayFields.depositAddress(json['deposit']) : null,
      label: label is String && label.isNotEmpty
          ? RelayFields.text(label, field: 'label', maxBytes: 64)
          : null,
      maxItems: maxItems is int && maxItems > 0 ? maxItems : null,
      maxBytes: maxBytes is int && maxBytes > 0 ? maxBytes : null,
    );
  }
}

class RelayMailboxInfo {
  final String deposit;
  final String? label;
  final int items;
  final int bytes;
  final bool enabled;
  final int? oldestExpiresAt;

  const RelayMailboxInfo({
    required this.deposit,
    required this.items,
    required this.bytes,
    required this.enabled,
    this.label,
    this.oldestExpiresAt,
  });

  Map<String, dynamic> toJson() => {
        'deposit': deposit,
        if (label != null) 'label': label,
        'items': items,
        'bytes': bytes,
        'enabled': enabled,
        'oldestExpiresAt': oldestExpiresAt,
      };

  static RelayMailboxInfo fromJson(Map<String, dynamic> json) => RelayMailboxInfo(
        deposit: RelayFields.depositAddress(json['deposit']),
        label: json['label'] as String?,
        items: json['items'] is int ? json['items'] as int : 0,
        bytes: json['bytes'] is int ? json['bytes'] as int : 0,
        enabled: json['enabled'] != false,
        oldestExpiresAt: json['oldestExpiresAt'] as int?,
      );
}

class RelayUsage {
  final int items;
  final int bytes;
  final int mailboxes;
  final int? oldestExpiresAt;

  const RelayUsage({
    required this.items,
    required this.bytes,
    required this.mailboxes,
    this.oldestExpiresAt,
  });

  Map<String, dynamic> toJson() => {
        'items': items,
        'bytes': bytes,
        'mailboxes': mailboxes,
        'oldestExpiresAt': oldestExpiresAt,
      };

  static RelayUsage fromJson(Map<String, dynamic> json) => RelayUsage(
        items: json['items'] is int ? json['items'] as int : 0,
        bytes: json['bytes'] is int ? json['bytes'] as int : 0,
        mailboxes: json['mailboxes'] is int ? json['mailboxes'] as int : 0,
        oldestExpiresAt: json['oldestExpiresAt'] as int?,
      );
}

class RelayStatusResponse {
  final RelayContract contract;
  final RelayUsage usage;
  final RelayLimits limits;
  final int serverTime;
  final List<RelayMailboxInfo> mailboxes;

  const RelayStatusResponse({
    required this.contract,
    required this.usage,
    required this.limits,
    required this.serverTime,
    this.mailboxes = const [],
  });

  Map<String, dynamic> toJson() => {
        'contract': contract.toJson(),
        'usage': usage.toJson(),
        'limits': limits.toJson(),
        'serverTime': serverTime,
        'mailboxes': mailboxes.map((m) => m.toJson()).toList(),
      };

  static RelayStatusResponse fromJson(Map<String, dynamic> json) {
    final raw = json['mailboxes'];
    return RelayStatusResponse(
      contract: RelayContract.fromJson(
        RelayFields.object(json['contract'], field: 'contract'),
      ),
      usage: RelayUsage.fromJson(
        RelayFields.object(json['usage'], field: 'usage'),
      ),
      limits: RelayLimits.fromJson(
        RelayFields.object(json['limits'], field: 'limits'),
      ),
      serverTime: RelayFields.timestamp(json['serverTime'], field: 'serverTime'),
      mailboxes: raw is List
          ? raw
              .map((e) => RelayMailboxInfo.fromJson(
                    RelayFields.object(e, field: 'mailboxes[]'),
                  ))
              .toList()
          : const [],
    );
  }
}
