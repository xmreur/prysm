class ConversationPreferences {
  final String conversationId;
  final bool isPinned;
  final int? pinnedAt;
  final bool isArchived;
  final int? archivedAt;

  const ConversationPreferences({
    required this.conversationId,
    this.isPinned = false,
    this.pinnedAt,
    this.isArchived = false,
    this.archivedAt,
  });

  factory ConversationPreferences.fromMap(Map<String, dynamic> map) {
    return ConversationPreferences(
      conversationId: map['conversationId'] as String,
      isPinned: (map['isPinned'] as int? ?? 0) == 1,
      pinnedAt: map['pinnedAt'] as int?,
      isArchived: (map['isArchived'] as int? ?? 0) == 1,
      archivedAt: map['archivedAt'] as int?,
    );
  }

  Map<String, dynamic> toMap() => {
        'conversationId': conversationId,
        'isPinned': isPinned ? 1 : 0,
        'pinnedAt': pinnedAt,
        'isArchived': isArchived ? 1 : 0,
        'archivedAt': archivedAt,
      };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ConversationPreferences &&
            other.conversationId == conversationId &&
            other.isPinned == isPinned &&
            other.pinnedAt == pinnedAt &&
            other.isArchived == isArchived &&
            other.archivedAt == archivedAt;
  }

  @override
  int get hashCode => Object.hash(
        conversationId,
        isPinned,
        pinnedAt,
        isArchived,
        archivedAt,
      );
}
