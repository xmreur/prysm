/// Filesystem storage exactly as spec §5. All writes are atomic
/// (write to `<file>.tmp` then `rename`); the deposit->owner index lives in
/// memory, is rebuilt from disk at boot, and is persisted on change.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';

class MailboxPolicy {
  MailboxPolicy({
    this.label,
    this.enabled = true,
    this.maxItems,
    this.maxBytes,
  });

  String? label;
  bool enabled;
  int? maxItems;
  int? maxBytes;

  Map<String, dynamic> toJson() => {
        if (label != null) 'label': label,
        'enabled': enabled,
        if (maxItems != null) 'maxItems': maxItems,
        if (maxBytes != null) 'maxBytes': maxBytes,
      };

  static MailboxPolicy fromJson(Map<String, dynamic> json) => MailboxPolicy(
        label: json['label'] as String?,
        enabled: json['enabled'] != false,
        maxItems: json['maxItems'] is int ? json['maxItems'] as int : null,
        maxBytes: json['maxBytes'] is int ? json['maxBytes'] as int : null,
      );
}

class StoredItem {
  StoredItem({
    required this.itemId,
    required this.deposit,
    required this.storedAt,
    required this.expiresAt,
    required this.size,
    required this.payload,
  });

  final String itemId;
  final String deposit;
  final int storedAt;
  final int expiresAt;
  final int size;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'deposit': deposit,
        'storedAt': storedAt,
        'expiresAt': expiresAt,
        'size': size,
        'payload': payload,
      };

  static StoredItem fromJson(Map<String, dynamic> json) => StoredItem(
        itemId: json['itemId'] as String,
        deposit: json['deposit'] as String,
        storedAt: json['storedAt'] as int,
        expiresAt: json['expiresAt'] as int,
        size: json['size'] is int ? json['size'] as int : 0,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
      );

  RelayItem toRelayItem() => RelayItem(
        itemId: itemId,
        deposit: deposit,
        storedAt: storedAt,
        expiresAt: expiresAt,
        size: size,
        payload: payload,
      );
}

/// One setup/invite token: single-use, expiring.
class TokenEntry {
  TokenEntry({
    required this.token,
    required this.createdAt,
    required this.expiresAt,
    this.usedBy,
  });

  final String token;
  final int createdAt;
  final int expiresAt;
  String? usedBy;

  bool get used => usedBy != null;
  bool expiredAt(int nowMs) => nowMs >= expiresAt;

  Map<String, dynamic> toJson() => {
        'token': token,
        'createdAt': createdAt,
        'expiresAt': expiresAt,
        if (usedBy != null) 'usedBy': usedBy,
      };

  static TokenEntry fromJson(Map<String, dynamic> json) => TokenEntry(
        token: json['token'] as String,
        createdAt: json['createdAt'] as int,
        expiresAt: json['expiresAt'] as int,
        usedBy: json['usedBy'] as String?,
      );

  static final Random _random = Random.secure();

  /// 32 random bytes, lowercase hex.
  static String newToken() => [
        for (var i = 0; i < 32; i++)
          _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join();
}
/// One tenant: the signed contract, the owner's public keys (for auth
/// verification), its mailboxes and its items.
class TenantData {
  TenantData({
    required this.contractJson,
    required this.ownerSignPublic,
    required this.ownerAgreePublic,
  });

  Map<String, dynamic> contractJson;
  List<int> ownerSignPublic;
  List<int> ownerAgreePublic;
  final Map<String, MailboxPolicy> mailboxes = {};
  final Map<String, StoredItem> items = {};

  RelayLimits limits() =>
      RelayLimits.fromJson(Map<String, dynamic>.from(contractJson['limits'] as Map));
}

class RelayStore {
  RelayStore(this.dataDir);

  final String dataDir;
  final Map<String, TenantData> tenants = {};
  final Map<String, String> depositIndex = {};
  final List<TokenEntry> tokens = [];

  String get _tokensPath => p.join(dataDir, 'tokens.json');
  String get _indexPath => p.join(dataDir, 'index.json');
  String _tenantDir(String ownerFpr) => p.join(dataDir, 'tenants', ownerFpr);
  String _mailboxDir(String ownerFpr, String deposit) =>
      p.join(_tenantDir(ownerFpr), 'mailboxes', deposit);
  String _itemsDir(String ownerFpr, String deposit) =>
      p.join(_mailboxDir(ownerFpr, deposit), 'items');

  /// Creates the layout if missing, loads everything, rebuilds the index and
  /// persists it.
  static Future<RelayStore> open(String dataDir) async {
    final store = RelayStore(dataDir);
    await Directory(dataDir).create(recursive: true);
    await store._restrict(dataDir, '700');
    await Directory(p.join(dataDir, 'tenants')).create(recursive: true);
    await store._loadTokens();
    await store._loadTenants();
    store._rebuildIndex();
    await store._saveIndex();
    return store;
  }

  // -- tokens ---------------------------------------------------------------

  TokenEntry addToken({required int ttlHours, required int nowMs}) {
    final entry = TokenEntry(
      token: TokenEntry.newToken(),
      createdAt: nowMs,
      expiresAt: nowMs + ttlHours * 3600 * 1000,
    );
    tokens.add(entry);
    return entry;
  }

  /// Merges `tokens.json` into memory so tokens minted by `token new` while
  /// the relay is running become valid without a restart. Disk-only entries
  /// are added; for entries on both sides a recorded consumption wins either
  /// way. In-memory entries are never dropped here (that is the sweeper's
  /// job), so a token added moments ago pairs even if the disk write lands
  /// later. A missing file keeps memory untouched.
  Future<void> reloadTokens() async {
    final file = File(_tokensPath);
    if (!file.existsSync()) return;
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! List) throw const FormatException('tokens.json is not a list');
    final mem = <String, TokenEntry>{for (final t in tokens) t.token: t};
    for (final e in raw) {
      final disk = TokenEntry.fromJson(Map<String, dynamic>.from(e as Map));
      final m = mem[disk.token];
      if (m == null) {
        tokens.add(disk);
      } else {
        m.usedBy ??= disk.usedBy;
      }
    }
  }


  TokenEntry? findToken(String token) {
    for (final t in tokens) {
      if (t.token == token) return t;
    }
    return null;
  }

  Future<void> saveTokens() => _writeJson(_tokensPath, [
        for (final t in tokens) t.toJson(),
      ]);

  /// Drops used and expired tokens. Returns how many were dropped.
  Future<int> pruneTokens(int nowMs) async {
    final before = tokens.length;
    tokens.removeWhere((t) => t.used || t.expiredAt(nowMs));
    final dropped = before - tokens.length;
    if (dropped > 0) await saveTokens();
    return dropped;
  }

  Future<void> _loadTokens() async {
    final file = File(_tokensPath);
    if (!file.existsSync()) {
      await _writeJson(_tokensPath, []);
      return;
    }
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! List) throw const FormatException('tokens.json is not a list');
    tokens
      ..clear()
      ..addAll(raw.map((e) => TokenEntry.fromJson(
            Map<String, dynamic>.from(e as Map),
          )));
  }

  // -- tenants ---------------------------------------------------------------

  /// Creates or replaces a tenant's contract + owner keys (re-pair keeps
  /// mailboxes and items: only the contract and keys are overwritten).
  Future<void> putTenant(
    String ownerFpr,
    Map<String, dynamic> contractJson,
    List<int> ownerSignPublic,
    List<int> ownerAgreePublic,
  ) async {
    RelayFields.fingerprint(ownerFpr, field: 'ownerFingerprint');
    final existing = tenants[ownerFpr];
    final tenant = existing ??
        TenantData(
          contractJson: contractJson,
          ownerSignPublic: ownerSignPublic,
          ownerAgreePublic: ownerAgreePublic,
        );
    tenant.contractJson = contractJson;
    tenant.ownerSignPublic = ownerSignPublic;
    tenant.ownerAgreePublic = ownerAgreePublic;
    tenants[ownerFpr] = tenant;
    final dir = Directory(_tenantDir(ownerFpr));
    await dir.create(recursive: true);
    await _writeJson(p.join(dir.path, 'contract.json'), contractJson);
    await _writeJson(p.join(dir.path, 'owner.json'), {
      'signPublic': base64Encode(ownerSignPublic),
      'agreePublic': base64Encode(ownerAgreePublic),
    });
  }

  /// Deletes tenant, mailboxes and items. Returns how many items died.
  Future<int> removeTenant(String ownerFpr) async {
    final tenant = tenants.remove(ownerFpr);
    final died = tenant?.items.length ?? 0;
    depositIndex.removeWhere((_, v) => v == ownerFpr);
    final dir = Directory(_tenantDir(ownerFpr));
    if (dir.existsSync()) await dir.delete(recursive: true);
    await _saveIndex();
    return died;
  }

  Future<void> _loadTenants() async {
    final root = Directory(p.join(dataDir, 'tenants'));
    if (!root.existsSync()) return;
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final ownerFpr = p.basename(e.path);
      try {
        RelayFields.fingerprint(ownerFpr, field: 'ownerFingerprint');
      } catch (_) {
        continue; // Not ours; leave it alone.
      }
      final contractFile = File(p.join(e.path, 'contract.json'));
      final ownerFile = File(p.join(e.path, 'owner.json'));
      if (!contractFile.existsSync() || !ownerFile.existsSync()) continue;
      final contractJson =
          Map<String, dynamic>.from(jsonDecode(contractFile.readAsStringSync()) as Map);
      final ownerJson =
          Map<String, dynamic>.from(jsonDecode(ownerFile.readAsStringSync()) as Map);
      final tenant = TenantData(
        contractJson: contractJson,
        ownerSignPublic: base64Decode(ownerJson['signPublic'] as String),
        ownerAgreePublic: base64Decode(ownerJson['agreePublic'] as String),
      );
      tenants[ownerFpr] = tenant;
      final mailboxesDir = Directory(p.join(e.path, 'mailboxes'));
      if (!mailboxesDir.existsSync()) continue;
      await for (final m in mailboxesDir.list()) {
        if (m is! Directory) continue;
        final deposit = p.basename(m.path);
        try {
          RelayFields.depositAddress(deposit);
        } catch (_) {
          continue;
        }
        final policyFile = File(p.join(m.path, 'policy.json'));
        if (!policyFile.existsSync()) continue;
        try {
          tenant.mailboxes[deposit] = MailboxPolicy.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(policyFile.readAsStringSync()) as Map,
            ),
          );
        } catch (_) {
          continue; // Corrupt policy: skip, keep serving the rest.
        }
        final itemsDir = Directory(p.join(m.path, 'items'));
        if (!itemsDir.existsSync()) continue;
        await for (final f in itemsDir.list()) {
          if (f is! File || !f.path.endsWith('.json')) continue;
          try {
            final item = StoredItem.fromJson(
              Map<String, dynamic>.from(
                jsonDecode(f.readAsStringSync()) as Map,
              ),
            );
            tenant.items[item.itemId] = item;
          } catch (_) {
            continue; // Corrupt item: skip, keep serving the rest.
          }
        }
      }
    }
  }

  // -- mailboxes ---------------------------------------------------------------

  Future<void> putMailbox(
    String ownerFpr,
    String deposit,
    MailboxPolicy policy,
  ) async {
    RelayFields.depositAddress(deposit);
    tenants[ownerFpr]?.mailboxes[deposit] = policy;
    await Directory(_itemsDir(ownerFpr, deposit)).create(recursive: true);
    await _writeJson(
      p.join(_mailboxDir(ownerFpr, deposit), 'policy.json'),
      policy.toJson(),
    );
    depositIndex[deposit] = ownerFpr;
    await _saveIndex();
  }

  /// Deletes the mailbox, its items and its index entry. Returns items died.
  Future<int> removeMailbox(String ownerFpr, String deposit) async {
    final tenant = tenants[ownerFpr];
    var died = 0;
    if (tenant != null) {
      tenant.mailboxes.remove(deposit);
      tenant.items.removeWhere((_, item) {
        if (item.deposit == deposit) {
          died++;
          return true;
        }
        return false;
      });
    }
    depositIndex.remove(deposit);
    final dir = Directory(_mailboxDir(ownerFpr, deposit));
    if (dir.existsSync()) await dir.delete(recursive: true);
    await _saveIndex();
    return died;
  }

  // -- items -------------------------------------------------------------------

  Future<void> putItem(String ownerFpr, StoredItem item) async {
    tenants[ownerFpr]?.items[item.itemId] = item;
    await Directory(_itemsDir(ownerFpr, item.deposit)).create(recursive: true);
    await _writeJson(
      p.join(_itemsDir(ownerFpr, item.deposit), '${item.itemId}.json'),
      item.toJson(),
    );
  }

  /// Deletes one item file + memory entry. Returns true when it existed.
  Future<bool> removeItem(String ownerFpr, StoredItem item) async {
    final removed = tenants[ownerFpr]?.items.remove(item.itemId) != null;
    final file = File(p.join(_itemsDir(ownerFpr, item.deposit), '${item.itemId}.json'));
    if (file.existsSync()) await file.delete();
    return removed;
  }

  /// Deletes every item with `expiresAt <= nowMs`. Returns how many died.
  Future<int> deleteExpiredItems(int nowMs) async {
    var died = 0;
    for (final entry in tenants.entries) {
      final expired = entry.value.items.values
          .where((i) => i.expiresAt <= nowMs)
          .toList();
      for (final item in expired) {
        await removeItem(entry.key, item);
        died++;
      }
    }
    return died;
  }

  RelayUsage usageOf(String ownerFpr) {
    final tenant = tenants[ownerFpr];
    if (tenant == null) {
      return const RelayUsage(items: 0, bytes: 0, mailboxes: 0);
    }
    var bytes = 0;
    int? oldest;
    for (final item in tenant.items.values) {
      bytes += item.size;
      oldest = oldest == null
          ? item.expiresAt
          : (item.expiresAt < oldest ? item.expiresAt : oldest);
    }
    return RelayUsage(
      items: tenant.items.length,
      bytes: bytes,
      mailboxes: tenant.mailboxes.length,
      oldestExpiresAt: oldest,
    );
  }

  List<RelayMailboxInfo> mailboxInfos(String ownerFpr) {
    final tenant = tenants[ownerFpr];
    if (tenant == null) return const [];
    final out = <RelayMailboxInfo>[];
    for (final entry in tenant.mailboxes.entries) {
      var items = 0;
      var bytes = 0;
      int? oldest;
      for (final item in tenant.items.values) {
        if (item.deposit != entry.key) continue;
        items++;
        bytes += item.size;
        oldest = oldest == null
            ? item.expiresAt
            : (item.expiresAt < oldest ? item.expiresAt : oldest);
      }
      out.add(RelayMailboxInfo(
        deposit: entry.key,
        label: entry.value.label,
        items: items,
        bytes: bytes,
        enabled: entry.value.enabled,
        oldestExpiresAt: oldest,
      ));
    }
    out.sort((a, b) => a.deposit.compareTo(b.deposit));
    return out;
  }

  // -- index -------------------------------------------------------------------

  void _rebuildIndex() {
    depositIndex.clear();
    for (final tenant in tenants.entries) {
      for (final deposit in tenant.value.mailboxes.keys) {
        depositIndex[deposit] = tenant.key;
      }
    }
  }

  Future<void> _saveIndex() =>
      _writeJson(_indexPath, Map<String, String>.of(depositIndex));

  // -- io ----------------------------------------------------------------------

  Future<void> _writeJson(String path, Object? value) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(path);
  }

  Future<void> _restrict(String path, String mode) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', [mode, path]);
    } catch (_) {
      // Best effort; the atomic rename is the guarantee.
    }
  }
}
