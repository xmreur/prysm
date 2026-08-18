import 'package:flutter/widgets.dart';
import 'package:prysm/models/contact.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/models/group.dart';
import 'package:prysm/models/share_target.dart';
import 'package:prysm/models/shared_content.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/services/pending_share_store.dart';
import 'package:prysm/services/share_send_service.dart';
import 'package:prysm/theme/prysm_theme.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

class ShareTargetPickerScreen extends StatefulWidget {
  const ShareTargetPickerScreen({
    required this.content,
    required this.conversations,
    required this.userId,
    required this.userName,
    required this.userAvatarBase64,
    required this.contacts,
    required this.keyManager,
    required this.groupById,
    super.key,
  });

  final SharedContent content;
  final List<Conversation> conversations;
  final String userId;
  final String userName;
  final String? userAvatarBase64;
  final List<Contact> contacts;
  final KeyManager keyManager;
  final Group? Function(String groupId) groupById;

  @override
  State<ShareTargetPickerScreen> createState() =>
      _ShareTargetPickerScreenState();
}

class _ShareTargetPickerScreenState extends State<ShareTargetPickerScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  bool _sending = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<_SharePickerRow> get _rows {
    final query = _searchQuery.trim().toLowerCase();
    final rows = <_SharePickerRow>[];

    if (query.isEmpty ||
        context.l10n.chatWithMyself.toLowerCase().contains(query) ||
        context.l10n.notesToSelf.toLowerCase().contains(query)) {
      rows.add(
        _SharePickerRow(
          target: ShareTarget(
            kind: DetachedChatKind.self,
            conversationId: DetachedChatLaunch.selfConversationId,
            displayName: context.l10n.chatWithMyself,
          ),
          title: context.l10n.chatWithMyself,
          subtitle: context.l10n.notesToSelf,
          avatarName: widget.userName,
          avatarBase64: widget.userAvatarBase64,
        ),
      );
    }

    for (final conv in widget.conversations) {
      if (conv is DirectConversation &&
          BlockService.instance.isBlocked(conv.id)) {
        continue;
      }
      final title = conv.displayName;
      if (query.isNotEmpty && !title.toLowerCase().contains(query)) {
        continue;
      }

      if (conv is DirectConversation) {
        final contact = conv.contact;
        rows.add(
          _SharePickerRow(
            target: ShareTarget(
              kind: DetachedChatKind.direct,
              conversationId: contact.id,
              displayName: contact.displayName,
            ),
            title: contact.displayName,
            subtitle: contact.id,
            avatarName: contact.displayName,
            avatarBase64: contact.avatarBase64,
          ),
        );
      } else if (conv is GroupConversation) {
        final group = conv.group;
        rows.add(
          _SharePickerRow(
            target: ShareTarget(
              kind: DetachedChatKind.group,
              conversationId: group.id,
              displayName: group.name,
            ),
            title: group.name,
            subtitle: context.l10n.group,
            avatarName: group.name,
            avatarBase64: group.avatarBase64,
          ),
        );
      }
    }

    return rows;
  }

  String get _contentSummary {
    if (widget.content.isText) {
      final text = widget.content.text ?? '';
      if (text.length <= 80) return text;
      return '${text.substring(0, 77)}...';
    }
    return widget.content.fileName ?? 'Shared file';
  }

  Future<void> _sendTo(_SharePickerRow row) async {
    if (_sending) return;
    setState(() => _sending = true);

    final result = await ShareSendService.send(
      target: row.target,
      content: widget.content,
      userId: widget.userId,
      keyManager: widget.keyManager,
      contacts: widget.contacts,
      groupById: widget.groupById,
    );

    if (!mounted) return;
    setState(() => _sending = false);

    if (result.success) {
      PendingShareStore.instance.clear();
      showPrysmToast(context, 'Sent to ${row.target.displayName}');
      Navigator.of(context).pop(row.target);
      return;
    }

    showPrysmToast(
      context,
      result.errorMessage ?? 'Could not send shared content.',
    );
  }

  void _cancel() {
    PendingShareStore.instance.clear();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final tokens = context.prysmTokens;

    return PrysmPage(
      title: context.l10n.shareToPrysm,
      leading: PrysmIconButton(
        icon: PrysmIcons.close,
        onPressed: _sending ? null : _cancel,
      ),
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Text(
                  _contentSummary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: PrysmTextField(
                  controller: _searchController,
                  hintText: 'Search conversations',
                  onChanged: (value) =>
                      setState(() => _searchQuery = value.toLowerCase()),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: rows.isEmpty
                    ? Center(
                        child: Text(
                          'No conversations found',
                          style: TextStyle(color: tokens.textSecondary),
                        ),
                      )
                    : ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            child: PrysmListRow(
                              leading: ContactAvatar(
                                name: row.avatarName,
                                avatarBase64: row.avatarBase64,
                              ),
                              title: row.title,
                              subtitle: row.subtitle,
                              onTap: _sending ? null : () => _sendTo(row),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
          if (_sending)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(child: PrysmProgressIndicator()),
            ),
        ],
      ),
    );
  }
}

class _SharePickerRow {
  const _SharePickerRow({
    required this.target,
    required this.title,
    required this.subtitle,
    required this.avatarName,
    this.avatarBase64,
  });

  final ShareTarget target;
  final String title;
  final String subtitle;
  final String avatarName;
  final String? avatarBase64;
}
