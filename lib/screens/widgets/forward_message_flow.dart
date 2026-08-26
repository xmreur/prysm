import 'package:flutter/widgets.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/models/shared_content.dart';
import 'package:prysm/screens/share_target_picker_screen.dart';
import 'package:prysm/services/message_forward_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_modify_policy.dart';

Future<void> openForwardMessagePicker({
  required BuildContext context,
  required Message message,
  required DetachedChatKind sourceKind,
  required String sourceConversationId,
  required String userId,
  required KeyManager keyManager,
  required List<Conversation> conversations,
  required List<Contact> contacts,
  required Group? Function(String groupId) groupById,
  String? userName,
  String? userAvatarBase64,
}) async {
  if (!canForwardMessage(message)) return;

  final settings = SettingsService();
  await Navigator.of(context).push(
    PrysmPageRoute(
      page: ShareTargetPickerScreen(
        content: SharedContent(
          kind: SharedContentKind.text,
          text: _preview(message, context),
        ),
        conversations: conversations,
        userId: userId,
        userName: userName ?? settings.username ?? userId,
        userAvatarBase64: userAvatarBase64 ?? settings.avatar,
        contacts: contacts,
        keyManager: keyManager,
        groupById: groupById,
        showForwardedToggle: true,
        customSend: (target, {required markForwarded}) {
          return MessageForwardService.forward(
            message: message,
            target: target,
            markForwarded: markForwarded,
            sourceKind: sourceKind,
            sourceConversationId: sourceConversationId,
            userId: userId,
            keyManager: keyManager,
            contacts: contacts,
            groupById: groupById,
          );
        },
      ),
    ),
  );
}

String _preview(Message message, BuildContext context) {
  if (message is TextMessage) return message.text;
  if (message is FileMessage) return message.name;
  if (message is ImageMessage) return context.l10n.image;
  return '';
}
