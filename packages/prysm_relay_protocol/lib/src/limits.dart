import 'errors.dart';
import 'protocol.dart';

/// The negotiable part of a Contract: what a relay is willing to store.
///
/// Defaults come from the prior-art research: a 20-day TTL matches chatmail's
/// `delete_mails_after` and SimpleX's ~21 days, and a 256-item mailbox is twice
/// SimpleX's 128-per-queue quota.
class RelayLimits {
  final int maxItemBytes;
  final int maxMailboxItems;
  final int maxTenantBytes;
  final int itemTtlSeconds;
  final int maxMailboxes;
  final int pickupBatchItems;
  final int pickupBatchBytes;

  /// Padding block size. Always 0 in v1; declared from v1 so switching padding
  /// on later is not a breaking wire change.
  final int blockSize;

  const RelayLimits({
    required this.maxItemBytes,
    required this.maxMailboxItems,
    required this.maxTenantBytes,
    required this.itemTtlSeconds,
    required this.maxMailboxes,
    this.pickupBatchItems = 64,
    this.pickupBatchBytes = 8 * 1024 * 1024,
    this.blockSize = 0,
  });

  static const int day = 24 * 60 * 60;

  /// Defaults for a relay serving a single identity: generous.
  static const RelayLimits privateDefaults = RelayLimits(
    maxItemBytes: 8 * 1024 * 1024,
    maxMailboxItems: 1024,
    maxTenantBytes: 256 * 1024 * 1024,
    itemTtlSeconds: 20 * day,
    maxMailboxes: 512,
  );

  /// Defaults for a relay accepting strangers: prudent.
  static const RelayLimits publicDefaults = RelayLimits(
    maxItemBytes: 1024 * 1024,
    maxMailboxItems: 256,
    maxTenantBytes: 64 * 1024 * 1024,
    itemTtlSeconds: 20 * day,
    maxMailboxes: 256,
  );

  static RelayLimits defaultsFor(RelayTenancy tenancy) =>
      tenancy == RelayTenancy.private ? privateDefaults : publicDefaults;

  /// Clamps a client's request to what this relay offers. A client may ask for
  /// less, never for more; asking for more is not an error, it is simply
  /// reduced, which keeps pairing from failing over a number.
  RelayLimits clamp(Map<String, dynamic>? requested) {
    if (requested == null || requested.isEmpty) return this;
    int pick(String key, int ceiling) {
      final raw = requested[key];
      if (raw is! int || raw <= 0) return ceiling;
      return raw < ceiling ? raw : ceiling;
    }

    return RelayLimits(
      maxItemBytes: pick('maxItemBytes', maxItemBytes),
      maxMailboxItems: pick('maxMailboxItems', maxMailboxItems),
      maxTenantBytes: pick('maxTenantBytes', maxTenantBytes),
      itemTtlSeconds: pick('itemTtlSeconds', itemTtlSeconds),
      maxMailboxes: pick('maxMailboxes', maxMailboxes),
      pickupBatchItems: pickupBatchItems,
      pickupBatchBytes: pickupBatchBytes,
      blockSize: blockSize,
    );
  }

  Map<String, dynamic> toJson() => {
        'maxItemBytes': maxItemBytes,
        'maxMailboxItems': maxMailboxItems,
        'maxTenantBytes': maxTenantBytes,
        'itemTtlSeconds': itemTtlSeconds,
        'maxMailboxes': maxMailboxes,
        'pickupBatchItems': pickupBatchItems,
        'pickupBatchBytes': pickupBatchBytes,
        'blockSize': blockSize,
      };

  /// Unknown keys are ignored on purpose: `limits` is the extensible part of
  /// the Contract, while an unknown `protocol` is a hard error.
  static RelayLimits fromJson(Map<String, dynamic> json) {
    int need(String key) {
      final raw = json[key];
      if (raw is! int || raw <= 0) {
        throw RelayError.badRequest('limits.$key must be a positive int');
      }
      return raw;
    }

    int optional(String key, int fallback) {
      final raw = json[key];
      return raw is int && raw >= 0 ? raw : fallback;
    }

    return RelayLimits(
      maxItemBytes: need('maxItemBytes'),
      maxMailboxItems: need('maxMailboxItems'),
      maxTenantBytes: need('maxTenantBytes'),
      itemTtlSeconds: need('itemTtlSeconds'),
      maxMailboxes: need('maxMailboxes'),
      pickupBatchItems: optional('pickupBatchItems', 64),
      pickupBatchBytes: optional('pickupBatchBytes', 8 * 1024 * 1024),
      blockSize: optional('blockSize', 0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RelayLimits &&
      other.maxItemBytes == maxItemBytes &&
      other.maxMailboxItems == maxMailboxItems &&
      other.maxTenantBytes == maxTenantBytes &&
      other.itemTtlSeconds == itemTtlSeconds &&
      other.maxMailboxes == maxMailboxes &&
      other.pickupBatchItems == pickupBatchItems &&
      other.pickupBatchBytes == pickupBatchBytes &&
      other.blockSize == blockSize;

  @override
  int get hashCode => Object.hash(maxItemBytes, maxMailboxItems, maxTenantBytes,
      itemTtlSeconds, maxMailboxes, pickupBatchItems, pickupBatchBytes, blockSize);
}
