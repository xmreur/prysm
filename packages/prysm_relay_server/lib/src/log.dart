/// Log policy from spec §5: at `logLevel: counters` never print a deposit
/// address beyond its first 6 hex chars, never a payload, never an owner
/// onion. `debug` relaxes this and MUST warn at startup.
library;

class RelayLog {
  RelayLog({required bool debug}) : _debug = debug;

  final bool _debug;

  bool get isDebug => _debug;

  /// One operational line. Callers MUST pre-redact: use [shortId] for deposit
  /// addresses and fingerprints, and never pass payloads or onions here when
  /// [isDebug] is false.
  void event(String message) {
    // ignore: avoid_print
    print(message);
  }

  void warn(String message) {
    // ignore: avoid_print
    print('[warn] $message');
  }

  /// First [length] chars of a hex id (deposit address, fingerprint).
  static String shortId(String hex, [int length = 6]) =>
      hex.length <= length ? hex : hex.substring(0, length);
}
