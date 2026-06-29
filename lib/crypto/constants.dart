/// Crypto v2 constants shared across Prysm.
class CryptoConstants {
  CryptoConstants._();

  static const String cryptoVersion = 'v2';
  static const String keystoreVersion = '2';

  static const int minPassphraseLength = 12;
  static const int saltLength = 16;
  static const int aeadKeyLength = 32;
  static const int gcmNonceLength = 12;

  /// Argon2id: 64 MiB, 3 iterations, 1 lane.
  static const int argon2MemoryKiB = 65536;
  static const int argon2Iterations = 3;
  static const int argon2Lanes = 1;

  static const String schemeDhAead1 = 'dh-aead-1';
  static const String schemeGroupAead1 = 'group-aead-1';
  static const String schemeControlWrap1 = 'control-wrap-1';
  static const String schemeFileAead1 = 'file-aead-1';
  static const String schemeCallAead1 = 'call-aead-1';
  static const String schemeRatchet1 = 'ratchet-1';
  static const String schemeGroupSender1 = 'group-sender-1';

  static const String hkdfInfoDhAead = 'prysm/dh-aead-1';
  static const String hkdfInfoGroupKey = 'prysm/group-key-wrap';
  static const String hkdfInfoCall = 'prysm/call-session';
  static const String hkdfInfoRatchet = 'prysm/ratchet';

  static const int backupVersion = 2;
  static const int cryptoGeneration = 2;
}
