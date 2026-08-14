class Contact {
  final String id;
  final String name;
  final String avatarUrl;
  final String? avatarBase64;
  final String? customName;
  final String identityJson;
  final String? verifiedFingerprint;
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
    this.verifiedFingerprint,
    this.lastMessageTimestamp,
  });

  factory Contact.fromMap(
    Map<String, dynamic> map, {
    int? lastMessageTimestamp,
  }) {
    return Contact(
      id: map['id'] as String,
      name: map['name'] as String? ?? '',
      avatarUrl: map['avatarUrl'] as String? ?? '',
      avatarBase64: map['avatarBase64'] as String?,
      customName: map['customName'] as String?,
      identityJson: (map['identityJson'] as String?) ??
          (map['publicKeyPem'] as String?) ??
          '',
      verifiedFingerprint: map['verifiedFingerprint'] as String?,
      lastMessageTimestamp: lastMessageTimestamp,
    );
  }

  Contact copyWith({
    String? id,
    String? name,
    String? avatarUrl,
    String? avatarBase64,
    String? customName,
    String? identityJson,
    String? verifiedFingerprint,
    int? lastMessageTimestamp,
  }) {
    return Contact(
      id: id ?? this.id,
      name: name ?? this.name,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      avatarBase64: avatarBase64 ?? this.avatarBase64,
      customName: customName ?? this.customName,
      identityJson: identityJson ?? this.identityJson,
      verifiedFingerprint: verifiedFingerprint ?? this.verifiedFingerprint,
      lastMessageTimestamp: lastMessageTimestamp ?? this.lastMessageTimestamp,
    );
  }
}
