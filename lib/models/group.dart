enum GroupRole { owner, admin, member }

String groupRoleToWire(GroupRole role) => switch (role) {
      GroupRole.owner => 'owner',
      GroupRole.admin => 'admin',
      GroupRole.member => 'member',
    };

GroupRole groupRoleFromWire(String? raw) {
  if (raw == 'owner') return GroupRole.owner;
  if (raw == 'admin') return GroupRole.admin;
  return GroupRole.member;
}

bool groupRoleIsModerator(GroupRole role) =>
    role == GroupRole.owner || role == GroupRole.admin;

class Group {
  final String id;
  final String name;
  final String? avatarBase64;
  final String createdBy;
  final int createdAt;
  final int? lastMessageTimestamp;
  final bool onlyAdminsCanAdd;

  Group({
    required this.id,
    required this.name,
    this.avatarBase64,
    required this.createdBy,
    required this.createdAt,
    this.lastMessageTimestamp,
    this.onlyAdminsCanAdd = true,
  });

  Group copyWith({
    String? name,
    String? avatarBase64,
    int? lastMessageTimestamp,
    bool? onlyAdminsCanAdd,
  }) {
    return Group(
      id: id,
      name: name ?? this.name,
      avatarBase64: avatarBase64 ?? this.avatarBase64,
      createdBy: createdBy,
      createdAt: createdAt,
      lastMessageTimestamp: lastMessageTimestamp ?? this.lastMessageTimestamp,
      onlyAdminsCanAdd: onlyAdminsCanAdd ?? this.onlyAdminsCanAdd,
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
      onlyAdminsCanAdd: (map['onlyAdminsCanAdd'] ?? 1) == 1,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'avatarBase64': avatarBase64,
        'createdBy': createdBy,
        'createdAt': createdAt,
        'onlyAdminsCanAdd': onlyAdminsCanAdd ? 1 : 0,
      };
}

class GroupMember {
  final String groupId;
  final String memberId;
  final GroupRole role;
  final int joinedAt;
  final bool muted;

  GroupMember({
    required this.groupId,
    required this.memberId,
    required this.role,
    required this.joinedAt,
    this.muted = false,
  });

  factory GroupMember.fromMap(Map<String, dynamic> map) {
    return GroupMember(
      groupId: map['groupId'] as String,
      memberId: map['memberId'] as String,
      role: groupRoleFromWire(map['role'] as String?),
      joinedAt: map['joinedAt'] as int,
      muted: (map['muted'] ?? 0) == 1,
    );
  }

  Map<String, dynamic> toMap() => {
        'groupId': groupId,
        'memberId': memberId,
        'role': groupRoleToWire(role),
        'joinedAt': joinedAt,
        'muted': muted ? 1 : 0,
      };
}
