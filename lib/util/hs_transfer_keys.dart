import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Hidden-service key transfer: raw Tor `hidden_service` files as base64.
///
/// The onion address derives from `hs_ed25519_secret_key`, so moving these
/// three files preserves the account's onion/Prysm ID. Desktop stores them
/// under the Tor data dir; mobile keeps them in plugin-private storage and
/// reaches them only through the native `prysm_tor` channel (see
/// `TorManager`), never through this file helper.
class HsTransferKeys {
  HsTransferKeys._();

  static const String hostnameFile = 'hostname';
  static const String secretKeyFile = 'hs_ed25519_secret_key';
  static const String publicKeyFile = 'hs_ed25519_public_key';

  static String hsDirForDocuments(String documentsDir) => p.join(
        documentsDir,
        'prysm',
        'tor_executable',
        'tor_data',
        'hidden_service',
      );

  /// Reads the three HS files from [hsDir]; null when any is missing.
  static Future<Map<String, String>?> collectFromDirectory(
    String hsDir,
  ) async {
    try {
      final hostname =
          await File(p.join(hsDir, hostnameFile)).readAsString();
      final secret =
          await File(p.join(hsDir, secretKeyFile)).readAsBytes();
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
  static Future<bool> installToDirectory(
    String hsDir,
    Map<String, String> keys,
  ) async {
    try {
      final hostnameB64 = keys[hostnameFile];
      final secretB64 = keys[secretKeyFile];
      final publicB64 = keys[publicKeyFile];
      if (hostnameB64 == null || secretB64 == null || publicB64 == null) {
        return false;
      }
      final hostname = utf8.decode(base64Decode(hostnameB64));
      final secret = base64Decode(secretB64);
      final public = base64Decode(publicB64);
      if (hostname.trim().isEmpty || secret.isEmpty || public.isEmpty) {
        return false;
      }
      final dir = Directory(hsDir);
      await dir.create(recursive: true);
      await File(p.join(hsDir, secretKeyFile)).writeAsBytes(secret);
      await File(p.join(hsDir, publicKeyFile)).writeAsBytes(public);
      await File(p.join(hsDir, hostnameFile)).writeAsString(hostname);
      await _lockDown(hsDir);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Tor refuses overly-permissive key material: best-effort 0700/0600 on
  /// POSIX, no-op elsewhere. Failures are ignored (install still reports
  /// success; Tor logs the complaint itself).
  static Future<void> _lockDown(String hsDir) async {
    if (Platform.isWindows || Platform.isAndroid || Platform.isIOS) return;
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
}
