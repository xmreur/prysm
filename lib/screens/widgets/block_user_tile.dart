import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_button.dart';

class BlockUserTile extends StatefulWidget {
  final String peerId;
  final VoidCallback? onBlocked;
  final VoidCallback? onUnblocked;

  const BlockUserTile({
    required this.peerId,
    this.onBlocked,
    this.onUnblocked,
    super.key,
  });

  @override
  State<BlockUserTile> createState() => _BlockUserTileState();
}

class _BlockUserTileState extends State<BlockUserTile> {
  void _refresh() => setState(() {});

  Future<void> _confirmBlock() async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Block contact',
      content: const Text(
        'You will no longer receive messages, calls, or profile updates from this contact.',
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Block',
      confirmVariant: PrysmButtonVariant.danger,
    );
    if (confirmed != true || !mounted) return;

    await BlockService.instance.block(widget.peerId);
    widget.onBlocked?.call();
    _refresh();
  }

  Future<void> _confirmUnblock() async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Unblock contact',
      content: const Text(
        'This contact will be able to message and call you again.',
      ),
      cancelLabel: 'Cancel',
      confirmLabel: 'Unblock',
    );
    if (confirmed != true || !mounted) return;

    await BlockService.instance.unblock(widget.peerId);
    widget.onUnblocked?.call();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.prysmStyle.tokens;
    final blocked = BlockService.instance.isBlocked(widget.peerId);

    return PrysmListRow(
      leading: Icon(
        blocked ? PrysmIcons.block : PrysmIcons.blockOutlined,
        color: blocked ? tokens.danger : null,
      ),
      title: blocked ? 'Unblock contact' : 'Block contact',
      titleWidget: Text(
        blocked ? 'Unblock contact' : 'Block contact',
        style: TextStyle(color: blocked ? tokens.danger : null),
      ),
      subtitle: blocked
          ? 'Tap to allow messages and calls again'
          : 'Stop messages, calls, and profile updates',
      onTap: blocked ? _confirmUnblock : _confirmBlock,
    );
  }
}
