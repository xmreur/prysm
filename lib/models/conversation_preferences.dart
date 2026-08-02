class ConversationPreferences {
  final String conversationId;
  final bool isPinned;
  final int? pinnedAt;
  final bool isArchived;
  final int? archivedAt;
  /// Per-conversation disappearing-messages timer in seconds; null = off.
  final int? disappearingTimerSeconds;

  const ConversationPreferences({
    required this.conversationId,
    this.isPinned = false,
    this.pinnedAt,
    this.isArchived = false,
    this.archivedAt,
    this.disappearingTimerSeconds,
  });

  factory ConversationPreferences.fromMap(Map<String, dynamic> map) {
    return ConversationPreferences(
      conversationId: map['conversationId'] as String,
      isPinned: (map['isPinned'] as int? ?? 0) == 1,
      pinnedAt: map['pinnedAt'] as int?,
      isArchived: (map['isArchived'] as int? ?? 0) == 1,
      archivedAt: map['archivedAt'] as int?,
      disappearingTimerSeconds: map['disappearingTimerSeconds'] as int?,
    );
  }

  Map<String, dynamic> toMap() => {
        'conversationId': conversationId,
        'isPinned': isPinned ? 1 : 0,
        'pinnedAt': pinnedAt,
        'isArchived': isArchived ? 1 : 0,
        'archivedAt': archivedAt,
        'disappearingTimerSeconds': disappearingTimerSeconds,
      };

  ConversationPreferences copyWith({
    bool? isPinned,
    int? pinnedAt,
    bool? isArchived,
    int? archivedAt,
    int? disappearingTimerSeconds,
    bool clearDisappearingTimer = false,
  }) {
    return ConversationPreferences(
      conversationId: conversationId,
      isPinned: isPinned ?? this.isPinned,
      pinnedAt: pinnedAt ?? this.pinnedAt,
      isArchived: isArchived ?? this.isArchived,
      archivedAt: archivedAt ?? this.archivedAt,
      disappearingTimerSeconds: clearDisappearingTimer
          ? null
          : (disappearingTimerSeconds ?? this.disappearingTimerSeconds),
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ConversationPreferences &&
            other.conversationId == conversationId &&
            other.isPinned == isPinned &&
            other.pinnedAt == pinnedAt &&
            other.isArchived == isArchived &&
            other.archivedAt == archivedAt &&
            other.disappearingTimerSeconds == disappearingTimerSeconds;
  }

  @override
  int get hashCode => Object.hash(
        conversationId,
        isPinned,
        pinnedAt,
        isArchived,
        archivedAt,
        disappearingTimerSeconds,
      );
}
