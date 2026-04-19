class Contact {
  final String id;
  final String name;
  final String avatarUrl;
  final String? avatarBase64;
  final String? customName;
  final String publicKeyPem;
  final int? lastMessageTimestamp;

  /// Shows customName if set, otherwise the remote name
  String get displayName => (customName != null && customName!.isNotEmpty) ? customName! : name;

  Contact({
    required this.id,
    required this.name,
    required this.avatarUrl,
    this.avatarBase64,
    this.customName,
    required this.publicKeyPem,
    this.lastMessageTimestamp,
  });
}
