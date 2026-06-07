class Contact {
  final String id;
  final String name;
  final String avatarUrl;
  final String? avatarBase64;
  final String? customName;
  final String publicKeyPem;
  final int? lastMessageTimestamp;
  final bool isMuted;

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
    this.isMuted = false,
  });

  Contact copyWith({bool? isMuted}) {
    return Contact(
      id: id,
      name: name,
      avatarUrl: avatarUrl,
      avatarBase64: avatarBase64,
      customName: customName,
      publicKeyPem: publicKeyPem,
      lastMessageTimestamp: lastMessageTimestamp,
      isMuted: isMuted ?? this.isMuted,
    );
  }
}
