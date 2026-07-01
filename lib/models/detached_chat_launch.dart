import 'dart:convert';

enum WindowLaunchKind { main, detachedChat }

enum DetachedChatKind { direct, group, self }

/// Window bootstrap payload for a pop-out chat window.
class DetachedChatLaunch {
  static const selfConversationId = '__self__';

  final WindowLaunchKind windowKind;
  final DetachedChatKind? chatKind;
  final String conversationId;
  final String title;
  final String userId;
  final String userName;
  final String? avatarBase64;
  final String? peerPublicKeyPem;
  final int themeIndex;

  const DetachedChatLaunch.main()
      : windowKind = WindowLaunchKind.main,
        chatKind = null,
        conversationId = '',
        title = '',
        userId = '',
        userName = '',
        avatarBase64 = null,
        peerPublicKeyPem = null,
        themeIndex = 0;

  const DetachedChatLaunch.detached({
    required this.chatKind,
    required this.conversationId,
    required this.title,
    required this.userId,
    required this.userName,
    this.avatarBase64,
    this.peerPublicKeyPem,
    this.themeIndex = 0,
  }) : windowKind = WindowLaunchKind.detachedChat;

  bool get isMain => windowKind == WindowLaunchKind.main;

  String toArguments() => jsonEncode(toJson());

  Map<String, dynamic> toJson() {
    if (isMain) {
      return {'windowKind': 'main'};
    }
    return {
      'windowKind': 'detached',
      'chatKind': chatKind!.name,
      'conversationId': conversationId,
      'title': title,
      'userId': userId,
      'userName': userName,
      'avatarBase64': avatarBase64,
      'peerPublicKeyPem': peerPublicKeyPem,
      'themeIndex': themeIndex,
    };
  }

  static DetachedChatLaunch parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const DetachedChatLaunch.main();
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final kind = map['windowKind'] as String? ?? 'main';
      if (kind != 'detached') {
        return const DetachedChatLaunch.main();
      }
      return DetachedChatLaunch.detached(
        chatKind: DetachedChatKind.values.byName(map['chatKind'] as String),
        conversationId: map['conversationId'] as String,
        title: map['title'] as String? ?? '',
        userId: map['userId'] as String,
        userName: map['userName'] as String? ?? '',
        avatarBase64: map['avatarBase64'] as String?,
        peerPublicKeyPem: map['peerPublicKeyPem'] as String?,
        themeIndex: map['themeIndex'] as int? ?? 0,
      );
    } catch (_) {
      return const DetachedChatLaunch.main();
    }
  }
}
