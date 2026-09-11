import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mutex/mutex.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/digests/sha3.dart';

/// Hidden-service key transfer: raw Tor `hidden_service` files as base64.
///
/// The onion address derives from `hs_ed25519_secret_key`, so moving these
/// three files preserves the account's onion/Prysm ID. Desktop stores them
/// under the Tor data dir; mobile keeps them in plugin-private storage and
/// reaches them only through the native `prysm_tor` channel (see
/// `TorManager`), never through this file helper.
class HsTransferKeys {
  HsTransferKeys._();

  /// Single process-wide lock for every hidden-service dir mutation
  /// (install + delete, all platforms Dart-side). TorManager additionally
  /// holds its control mutex around these, serializing them against
  /// start/stop/restart.
  // ponytail: one global lock; per-dir locks if HS throughput ever matters.
  static final Mutex opMutex = Mutex();

  static const String hostnameFile = 'hostname';
  static const String secretKeyFile = 'hs_ed25519_secret_key';
  static const String publicKeyFile = 'hs_ed25519_public_key';

  /// Pending-install marker: present only between the first promote and a
  /// verified complete triplet. A process death in that window leaves it
  /// behind, and [repairInterruptedInstall] purges the possibly-mixed set
  /// before Tor can read it.
  static const String pendingMarkerFile = '.hs_install_pending';

  static const String _secretHeader = '== ed25519v1-secret: type0 ==';
  static const String _publicHeader = '== ed25519v1-public: type0 ==';
  static const int _secretFileLength = 96;
  static const int _publicFileLength = 64;
  static const int _headerLength = 32;

  /// True when the decoded triplet is a real Tor v3 identity: both key files
  /// carry their Tor header and length, and the hostname is the onion
  /// address derived from the public key. Base64-clean but malformed input
  /// would otherwise install an unusable onion and report success.
  static bool isValidTriplet({
    required List<int> secret,
    required List<int> public,
    required String hostname,
  }) {
    if (secret.length != _secretFileLength ||
        public.length != _publicFileLength) {
      return false;
    }
    if (!_hasHeader(secret, _secretHeader) ||
        !_hasHeader(public, _publicHeader)) {
      return false;
    }
    final pubKey = public.sublist(_headerLength);
    return hostname.trim().toLowerCase() == onionFromPublicKey(pubKey);
  }

  /// Tor v3 address: base32(pubkey ‖ checksum ‖ version) + '.onion', with
  /// checksum = SHA3-256('.onion checksum' ‖ pubkey ‖ version)[0..1].
  static String onionFromPublicKey(List<int> pubKey) {
    const version = 0x03;
    final digestInput = <int>[
      ...utf8.encode('.onion checksum'),
      ...pubKey,
      version,
    ];
    final digest = SHA3Digest(256).process(Uint8List.fromList(digestInput));
    final payload = <int>[...pubKey, digest[0], digest[1], version];
    return '${_base32Encode(payload)}.onion';
  }

  static bool _hasHeader(List<int> bytes, String header) {
    final expected = utf8.encode(header);
    for (var i = 0; i < expected.length; i++) {
      if (bytes[i] != expected[i]) return false;
    }
    // Header field is zero-padded to 32 bytes.
    for (var i = expected.length; i < _headerLength; i++) {
      if (bytes[i] != 0) return false;
    }
    return true;
  }

  /// [isValidTriplet] for the base64 map shape used by the backup manifest
  /// and the native channel.
  static bool isValidEncodedTriplet(Map<String, String> keys) {
    try {
      final hostnameB64 = keys[hostnameFile];
      final secretB64 = keys[secretKeyFile];
      final publicB64 = keys[publicKeyFile];
      if (hostnameB64 == null ||
          secretB64 == null ||
          publicB64 == null ||
          hostnameB64.isEmpty ||
          secretB64.isEmpty ||
          publicB64.isEmpty) {
        return false;
      }
      return isValidTriplet(
        secret: base64Decode(secretB64),
        public: base64Decode(publicB64),
        hostname: utf8.decode(base64Decode(hostnameB64)),
      );
    } catch (_) {
      return false;
    }
  }

  static String _base32Encode(List<int> bytes) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in bytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        out.write(alphabet[(buffer >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }
    if (bits > 0) {
      out.write(alphabet[(buffer << (5 - bits)) & 31]);
    }
    return out.toString();
  }

  static String hsDirForDocuments(String documentsDir) => p.join(
    documentsDir,
    'prysm',
    'tor_executable',
    'tor_data',
    'hidden_service',
  );

  /// Reads the three HS files from [hsDir]; null when any is missing.
  static Future<Map<String, String>?> collectFromDirectory(String hsDir) async {
    try {
      final hostname = await File(p.join(hsDir, hostnameFile)).readAsString();
      final secret = await File(p.join(hsDir, secretKeyFile)).readAsBytes();
      final public = await File(p.join(hsDir, publicKeyFile)).readAsBytes();
      if (hostname.trim().isEmpty || secret.isEmpty || public.isEmpty) {
        return null;
      }
      return {
        hostnameFile: base64Encode(utf8.encode(hostname)),
        secretKeyFile: base64Encode(secret),
        publicKeyFile: base64Encode(public),
      };
    } catch (_) {
      return null;
    }
  }

  /// Writes HS files into [hsDir] (created when missing). Must run before
  /// the first Tor start so Tor reuses the keys instead of generating new
  /// ones. False on any failure: the caller falls back to a fresh onion.
  /// Every field is validated before anything lands on disk, and files go
  /// through .tmp + rename, so bad input never leaves partial writes and a
  /// mid-write crash never leaves a torn key file.
  static Future<bool> installToDirectory(
    String hsDir,
    Map<String, String> keys,
  ) async {
    return opMutex.protect(() => _installUnlocked(hsDir, keys));
  }

  /// Deletes the HS dir (source deactivation). True when nothing remains.
  static Future<bool> deleteDirectory(String hsDir) async {
    return opMutex.protect(() async {
      try {
        final dir = Directory(hsDir);
        if (!await dir.exists()) return true;
        await dir.delete(recursive: true);
        return !(await dir.exists());
      } catch (_) {
        return false;
      }
    });
  }

  /// Purges a possibly-mixed triplet left by a process death mid-install.
  /// Must run before Tor reads [hsDir]; the next start mints a fresh onion
  /// (recoverable: the user restores the backup again). No-op without the
  /// marker. Returns true when a repair was performed.
  static Future<bool> repairInterruptedInstall(String hsDir) async {
    return opMutex.protect(() async {
      final marker = File(p.join(hsDir, pendingMarkerFile));
      try {
        if (!await marker.exists()) return false;
        await _deleteQuietly(File(p.join(hsDir, secretKeyFile)));
        await _deleteQuietly(File(p.join(hsDir, publicKeyFile)));
        await _deleteQuietly(File(p.join(hsDir, hostnameFile)));
        await _deleteQuietly(File(p.join(hsDir, '$secretKeyFile.tmp')));
        await _deleteQuietly(File(p.join(hsDir, '$publicKeyFile.tmp')));
        await _deleteQuietly(File(p.join(hsDir, '$hostnameFile.tmp')));
        await _deleteQuietly(marker);
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  static Future<bool> _installUnlocked(
    String hsDir,
    Map<String, String> keys,
  ) async {
    try {
      final hostnameB64 = keys[hostnameFile];
      final secretB64 = keys[secretKeyFile];
      final publicB64 = keys[publicKeyFile];
      if (hostnameB64 == null ||
          secretB64 == null ||
          publicB64 == null ||
          hostnameB64.isEmpty ||
          secretB64.isEmpty ||
          publicB64.isEmpty) {
        return false;
      }
      final hostname = utf8.decode(base64Decode(hostnameB64));
      final secret = base64Decode(secretB64);
      final public = base64Decode(publicB64);
      if (!isValidTriplet(secret: secret, public: public, hostname: hostname)) {
        return false;
      }
      final dir = Directory(hsDir);
      await dir.create(recursive: true);
      final secretFile = File(p.join(hsDir, secretKeyFile));
      final publicFile = File(p.join(hsDir, publicKeyFile));
      final hostnameFile_ = File(p.join(hsDir, hostnameFile));
      final secretTmp = File(p.join(hsDir, '$secretKeyFile.tmp'));
      final publicTmp = File(p.join(hsDir, '$publicKeyFile.tmp'));
      final hostnameTmp = File(p.join(hsDir, '$hostnameFile.tmp'));
      try {
        await secretTmp.writeAsBytes(secret);
        await publicTmp.writeAsBytes(public);
        await hostnameTmp.writeAsString(hostname);
      } catch (_) {
        // Staging failed before any promote: live keys untouched.
        await _deleteQuietly(secretTmp);
        await _deleteQuietly(publicTmp);
        await _deleteQuietly(hostnameTmp);
        return false;
      }
      final marker = File(p.join(hsDir, pendingMarkerFile));
      bool committed = false;
      try {
        // Marker first: a process death mid-promote leaves it behind and
        // repairInterruptedInstall() purges the mixed set before Tor runs.
        await marker.writeAsString('installing');
        committed =
            await _promote(secretTmp, secretFile) &&
            await _promote(publicTmp, publicFile) &&
            await _promote(hostnameTmp, hostnameFile_);
      } finally {
        await _deleteQuietly(secretTmp);
        await _deleteQuietly(publicTmp);
        await _deleteQuietly(hostnameTmp);
      }
      if (!committed ||
          !await _tripletPresent(secretFile, publicFile, hostnameFile_)) {
        // Mixed or incomplete: roll back to no keys so the caller falls
        // back to a fresh onion instead of a torn identity.
        await _deleteQuietly(secretFile);
        await _deleteQuietly(publicFile);
        await _deleteQuietly(hostnameFile_);
        await _deleteQuietly(marker);
        return false;
      }
      await _deleteQuietly(marker);
      await _lockDown(hsDir);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _promote(File tmp, File dest) async {
    try {
      await tmp.rename(dest.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _tripletPresent(File a, File b, File c) async {
    for (final f in [a, b, c]) {
      try {
        if (!await f.exists() || await f.length() == 0) return false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Tor refuses overly-permissive key material. POSIX: best-effort 0700/0600.
  /// Windows: best-effort `icacls` (strip inheritance, current user only) —
  /// Dart has no ACL API, so a locked-down host account remains the real
  /// guarantee. Mobile: no-op, keys live in plugin-private storage.
  /// Failures are ignored (install still reports success; Tor logs the
  /// complaint itself).
  static Future<void> _lockDown(String hsDir) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    if (Platform.isWindows) {
      await _lockDownWindows(hsDir);
      return;
    }
    try {
      await Process.run('chmod', ['700', hsDir]);
      await Process.run('chmod', [
        '600',
        p.join(hsDir, secretKeyFile),
        p.join(hsDir, publicKeyFile),
      ]);
    } catch (_) {
      // Best effort only.
    }
  }

  /// Best-effort Windows ACL lockdown: strip inheritance, grant the current
  /// user full control on the HS dir and both key files.
  static Future<void> _lockDownWindows(String hsDir) async {
    try {
      final user = Platform.environment['USERNAME'];
      if (user == null || user.isEmpty) return;
      for (final path in [
        hsDir,
        p.join(hsDir, secretKeyFile),
        p.join(hsDir, publicKeyFile),
      ]) {
        await Process.run('icacls', [
          path,
          '/inheritance:r',
          '/grant:r',
          '$user:(OI)(CI)F',
        ]);
      }
    } catch (_) {
      // Best effort only.
    }
  }
}
