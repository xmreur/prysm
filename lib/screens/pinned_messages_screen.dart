import 'package:flutter/widgets.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/pinned_messages_db.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/pinned_messages_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_preview_label.dart';
import 'package:prysm/crypto/group_crypto.dart';

class PinnedMessagesScreen extends StatefulWidget {
  const PinnedMessagesScreen({
    required this.conversationId,
    required this.scope,
    required this.keyManager,
    this.userId,
    this.groupService,
    super.key,
  });

  final String conversationId;
  final String scope;
  final KeyManager keyManager;
  final String? userId;
  final GroupService? groupService;

  @override
  State<PinnedMessagesScreen> createState() => _PinnedMessagesScreenState();
}

class _PinnedMessagesScreenState extends State<PinnedMessagesScreen> {
  List<PinnedMessageRow> _rows = const [];
  final Map<String, String> _snippets = {};
  var _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final rows = await PinnedMessagesService.listPinned(
      conversationId: widget.conversationId,
      scope: widget.scope,
    );
    final snippets = <String, String>{};
    for (final row in rows) {
      snippets[row.messageId] = await _snippet(row);
    }
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _snippets
        ..clear()
        ..addAll(snippets);
      _loading = false;
    });
  }

  Future<String> _snippet(PinnedMessageRow row) async {
    final fileName = row.fileName;
    if (fileName != null && fileName.isNotEmpty) return fileName;
    final type = row.type;
    if (type == 'image' ||
        type == groupImageType ||
        type == 'audio' ||
        type == groupAudioType ||
        type == 'file' ||
        type == groupFileType) {
      return previewLabelForType(type);
    }
    final cipher = row.ciphertext;
    if (cipher == null || cipher.isEmpty) {
      return previewLabelForType(type);
    }
    try {
      if (widget.scope == PinnedMessagesDb.scopeGroup) {
        final groupService = widget.groupService;
        final userId = widget.userId;
        if (groupService == null || userId == null) {
          return previewLabelForType(type);
        }
        final groupKey = await groupService.getDecryptedGroupKey(
          widget.conversationId,
        );
        if (groupKey == null) return previewLabelForType(type);
        if (GroupCryptoV2.isSenderKeyEnvelope(cipher)) {
          return previewLabelForType(type);
        }
        return await GroupCryptoV2.decryptText(groupKey, cipher);
      }
      return await widget.keyManager.decryptMessage(cipher);
    } catch (_) {
      return previewLabelForType(type);
    }
  }

  String _formatTime(int timestamp) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final date =
        '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  Future<void> _unpin(PinnedMessageRow row) async {
    await PinnedMessagesService.unpin(
      messageId: row.messageId,
      conversationId: widget.conversationId,
      scope: widget.scope,
    );
    if (!mounted) return;
    showPrysmToast(context, context.l10n.messageUnpinned);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    return PrysmPage(
      title: context.l10n.pinnedMessages,
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: () => Navigator.of(context).pop(),
      ),
      body: _loading
          ? const SizedBox.shrink()
          : _rows.isEmpty
              ? Center(
                  child: Text(
                    context.l10n.noPinnedMessages,
                    style: TextStyle(color: tokens.textMuted),
                  ),
                )
              : ListView.builder(
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    return PrysmListRow(
                      leading: const Icon(PrysmIcons.pushPin),
                      title: _snippets[row.messageId] ?? row.fileName ?? '',
                      subtitle: _formatTime(row.timestamp),
                      trailing: PrysmIconButton(
                        icon: PrysmIcons.pushPinOutlined,
                        onPressed: () => _unpin(row),
                      ),
                      onTap: () => Navigator.of(context).pop(row.messageId),
                    );
                  },
                ),
    );
  }
}
