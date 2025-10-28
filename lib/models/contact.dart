class Contact {
  final String id;
  final String name;
  final String avatarUrl;
  final String publicKeyPem;
  final int? lastMessageTimestamp;

  Contact({required this.id, required this.name, required this.avatarUrl, required this.publicKeyPem, this.lastMessageTimestamp});
}
