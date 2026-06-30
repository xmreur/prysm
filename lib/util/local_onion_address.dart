/// Local hidden-service onion, set after Tor bootstrap.
class LocalOnionAddress {
  LocalOnionAddress._();

  static String? Function()? provider;

  static String? get value => provider?.call();
}
