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
  /// Every field is validated before anything lands on disk, the dir is
  /// locked to 0700 before staging, and files go through .tmp + rename, so
  /// bad input never leaves partial writes and a mid-write crash never
  /// leaves a torn key file.
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

  /// Purges a possibly-mixed triplet left by a process death mid-install
  /// and reports whether [hsDir] is safe for Tor to read: true without a
  /// marker or once every key/tmp file is verified absent (the next start
  /// mints a fresh onion; the user restores the backup again). False when a
  /// file survived: the marker is kept so the next start retries, and the
  /// caller must not start Tor over the mixed set.
  static Future<bool> repairInterruptedInstall(String hsDir) async {
    return opMutex.protect(() async {
      final marker = File(p.join(hsDir, pendingMarkerFile));
      try {
        if (!await marker.exists()) return true;
        return await _purgeTriplet(hsDir) && await _deleteQuietly(marker);
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
      // Lock the dir down before any secret byte lands in it: a 0700 dir
      // shields the staged files whatever mode the umask gives them.
      if (!await _lockDown([hsDir], '700')) return false;
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
          !await _tripletPresent(secretFile, publicFile, hostnameFile_) ||
          !await _lockDown([secretFile.path, publicFile.path], '600')) {
        // Mixed, incomplete or not private: roll back to no keys. The
        // marker goes only once every file is verified gone, so a surviving
        // file makes the next start retry the purge instead of reading it.
        if (await _purgeTriplet(hsDir)) await _deleteQuietly(marker);
        return false;
      }
      // Marker last. If it survives, the next start purges this valid
      // triplet, so report failure rather than a success the restart undoes.
      return await _deleteQuietly(marker);
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

  /// Deletes live and staged key files; true only when all are verified
  /// absent afterwards.
  static Future<bool> _purgeTriplet(String hsDir) async {
    var purged = true;
    for (final name in [secretKeyFile, publicKeyFile, hostnameFile]) {
      purged = await _deleteQuietly(File(p.join(hsDir, name))) && purged;
      purged = await _deleteQuietly(File(p.join(hsDir, '$name.tmp'))) && purged;
    }
    return purged;
  }

  /// Best-effort delete; true when [file] is absent afterwards.
  static Future<bool> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
      return !await file.exists();
    } catch (_) {
      return false;
    }
  }

  /// Tor refuses an HS dir that is not 0700, and a secret in a traversable
  /// dir is readable by other local accounts, so on POSIX the chmod result
  /// and the resulting mode are both checked and a failure fails the
  /// install. Windows: best-effort `icacls` (strip inheritance, current user
  /// only) — Dart has no ACL API to verify, and %APPDATA% is already
  /// user-private by inheritance. Mobile: no-op, keys live in
  /// plugin-private storage.
  static Future<bool> _lockDown(List<String> paths, String mode) async {
    if (Platform.isAndroid || Platform.isIOS) return true;
    if (Platform.isWindows) {
      await _lockDownWindows(paths);
      return true;
    }
    try {
      final result = await Process.run('chmod', [mode, ...paths]);
      if (result.exitCode != 0) return false;
      final want = int.parse(mode, radix: 8);
      for (final path in paths) {
        if (((await FileStat.stat(path)).mode & 0x1ff) != want) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _lockDownWindows(List<String> paths) async {
    try {
      final user = Platform.environment['USERNAME'];
      if (user == null || user.isEmpty) return;
      for (final path in paths) {
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
