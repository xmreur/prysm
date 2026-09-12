/// The relay's Ed25519+X25519 key material: generated on `init`, persisted as
/// JSON, loaded at boot. The fingerprint and wire parsing are delegated to
/// the protocol package's [RelayIdentity] — never recomputed here — so the
/// app verifies us byte-for-byte.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:prysm_relay_protocol/prysm_relay_protocol.dart';

import 'permissions.dart';

class RelayKeyPair {
  RelayKeyPair({
    required SimpleKeyPair signKeyPair,
    required RelayIdentity identity,
  })  : _signKeyPair = signKeyPair,
        identity = identity;

  final SimpleKeyPair _signKeyPair;

  /// The relay's public identity. The agreement key exists purely so this
  /// fingerprint is computed over the same two keys as the app's
  /// `IdentityKeyPair.fingerprint`; only the public half is kept, because the
  /// relay never performs a key exchange.
  final RelayIdentity identity;

  String get fingerprint => identity.fingerprint;
  Uint8List get signPublic => identity.signPublic;
  Uint8List get agreePublic => identity.agreePublic;

  String toIdentityJsonString() => identity.toJsonString();

  static final Ed25519 _ed25519 = Ed25519();
  static final X25519 _x25519 = X25519();
  static final Random _random = Random.secure();

  /// Process-wide, not per call: two writers inside one process must not
  /// derive the same temp name either.
  static int _tmpSeq = 0;

  static Uint8List _seed() =>
      Uint8List.fromList(List<int>.generate(32, (_) => _random.nextInt(256)));

  static Future<RelayKeyPair> generate() async {
    final signSeed = _seed();
    final agreeSeed = _seed();
    return _fromSeeds(signSeed, agreeSeed);
  }

  static Future<RelayKeyPair> _fromSeeds(
    Uint8List signSeed,
    Uint8List agreeSeed,
  ) async {
    final signKeyPair = await _ed25519.newKeyPairFromSeed(signSeed);
    final agreeKeyPair = await _x25519.newKeyPairFromSeed(agreeSeed);
    final signPublic =
        Uint8List.fromList((await signKeyPair.extractPublicKey()).bytes);
    final agreePublic =
        Uint8List.fromList((await agreeKeyPair.extractPublicKey()).bytes);
    return RelayKeyPair(
      signKeyPair: signKeyPair,
      identity:
          RelayIdentity.fromKeys(signPublic: signPublic, agreePublic: agreePublic),
    );
  }

  static String pathFor(String dataDir) =>
      '$dataDir${Platform.pathSeparator}identity.json';

  /// Generates fresh keys and atomically writes `identity.json` (0600 where
  /// the platform allows it). Fails if the file already exists: init must
  /// never silently overwrite an identity clients already trust.
  static Future<RelayKeyPair> generateAndSave(String dataDir) async {
    final path = pathFor(dataDir);
    if (File(path).existsSync()) {
      throw StateError('identity already exists at $path');
    }
    final signSeed = _seed();
    final agreeSeed = _seed();
    final keys = await _fromSeeds(signSeed, agreeSeed);
    final doc = {
      'crypto': RelayIdentity.cryptoVersion,
      'signSeed': base64Encode(signSeed),
      'agreeSeed': base64Encode(agreeSeed),
      'signPublic': base64Encode(keys.signPublic),
      'agreePublic': base64Encode(keys.agreePublic),
      'fingerprint': keys.fingerprint,
    };
    // The mode is tightened on an empty file, *before* the seeds land in it:
    // a chmod that fails must not leave a readable copy of the private key.
    // The name carries the pid and a process-wide counter for the same reason
    // `RelayStore._writeJson` does: a fixed `identity.json.tmp` is shared
    // state, and a second writer's `rename` died on it with
    // `PathNotFoundException` once the first had moved the file away.
    final tmp = File('$path.$pid.${_tmpSeq++}.tmp');
    try {
      await tmp.create(recursive: true);
      await restrictPath(tmp.path, '600');
      await tmp.writeAsString(jsonEncode(doc), flush: true);
      await tmp.rename(path);
    } finally {
      if (tmp.existsSync()) await tmp.delete();
    }
    await restrictPath(path, '600');
    return keys;
  }

  static Future<RelayKeyPair> load(String dataDir) async {
    final path = pathFor(dataDir);
    if (!File(path).existsSync()) {
      throw StateError('no identity at $path; run `init` first');
    }
    final doc = jsonDecode(File(path).readAsStringSync());
    if (doc is! Map) {
      throw const FormatException('identity.json is not an object');
    }
    final map = Map<String, dynamic>.from(doc);
    if (map['crypto'] != RelayIdentity.cryptoVersion) {
      throw const FormatException('identity.json has an unsupported version');
    }
    final Uint8List signSeed;
    final Uint8List agreeSeed;
    try {
      signSeed = base64Decode(map['signSeed'] as String);
      agreeSeed = base64Decode(map['agreeSeed'] as String);
    } catch (_) {
      throw const FormatException('identity.json has corrupt seeds');
    }
    final keys = await _fromSeeds(signSeed, agreeSeed);
    // The file also carries the public keys + fingerprint: cross-check that
    // what is on disk matches what the seeds re-derive.
    final filed = RelayIdentity.parse({
      'crypto': RelayIdentity.cryptoVersion,
      'signPublic': map['signPublic'],
      'agreePublic': map['agreePublic'],
      'fingerprint': map['fingerprint'],
    });
    if (filed.fingerprint != keys.fingerprint) {
      throw const FormatException(
        'identity.json public keys do not match its seeds',
      );
    }
    return keys;
  }

  Future<String> sign(List<int> message) =>
      RelaySigning.sign(message, _signKeyPair);
}
