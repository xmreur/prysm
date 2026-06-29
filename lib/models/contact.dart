class Contact {
  final String id;
  final String name;
  final String avatarUrl;
  final String? avatarBase64;
  final String? customName;
  final String identityJson;
  final int? lastMessageTimestamp;

  String get displayName =>
      (customName != null && customName!.isNotEmpty) ? customName! : name;

  /// Legacy field name; stores v2 identity JSON.
  String get publicKeyPem => identityJson;

  Contact({
    required this.id,
    required this.name,
    required this.avatarUrl,
    this.avatarBase64,
    this.customName,
    required this.identityJson,
    this.lastMessageTimestamp,
  });
}
