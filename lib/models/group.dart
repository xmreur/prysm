enum GroupRole { admin, member }

class Group {
  final String id;
  final String name;
  final String? avatarBase64;
  final String createdBy;
  final int createdAt;
  final int? lastMessageTimestamp;

  Group({
    required this.id,
    required this.name,
    this.avatarBase64,
    required this.createdBy,
    required this.createdAt,
    this.lastMessageTimestamp,
  });

  Group copyWith({
    String? name,
    String? avatarBase64,
    int? lastMessageTimestamp,
  }) {
    return Group(
      id: id,
      name: name ?? this.name,
      avatarBase64: avatarBase64 ?? this.avatarBase64,
      createdBy: createdBy,
      createdAt: createdAt,
      lastMessageTimestamp: lastMessageTimestamp ?? this.lastMessageTimestamp,
    );
  }

  factory Group.fromMap(Map<String, dynamic> map, {int? lastMessageTimestamp}) {
    return Group(
      id: map['id'] as String,
      name: map['name'] as String,
      avatarBase64: map['avatarBase64'] as String?,
      createdBy: map['createdBy'] as String,
      createdAt: map['createdAt'] as int,
      lastMessageTimestamp: lastMessageTimestamp,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'avatarBase64': avatarBase64,
        'createdBy': createdBy,
        'createdAt': createdAt,
      };
}

class GroupMember {
  final String groupId;
  final String memberId;
  final GroupRole role;
  final int joinedAt;

  GroupMember({
    required this.groupId,
    required this.memberId,
    required this.role,
    required this.joinedAt,
  });

  factory GroupMember.fromMap(Map<String, dynamic> map) {
    return GroupMember(
      groupId: map['groupId'] as String,
      memberId: map['memberId'] as String,
      role: map['role'] == 'admin' ? GroupRole.admin : GroupRole.member,
      joinedAt: map['joinedAt'] as int,
    );
  }

  Map<String, dynamic> toMap() => {
        'groupId': groupId,
        'memberId': memberId,
        'role': role == GroupRole.admin ? 'admin' : 'member',
        'joinedAt': joinedAt,
      };
}
