enum UnlockType {
  pin,
  passphrase;

  String toJson() => name;

  static UnlockType fromJson(String? raw) {
    switch (raw) {
      case 'pin':
        return UnlockType.pin;
      case 'passphrase':
        return UnlockType.passphrase;
      default:
        return UnlockType.pin;
    }
  }
}
