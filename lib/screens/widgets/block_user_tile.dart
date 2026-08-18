import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/services/block_service.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/l10n/l10n_extensions.dart';

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
      title: context.l10n.blockContact,
      content: Text(context.l10n.youWillNoLongerReceiveMessagesCallsOr),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.block,
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
      title: context.l10n.unblockContact,
      content: Text(context.l10n.unblockContactBody),
      cancelLabel: context.l10n.cancel,
      confirmLabel: context.l10n.unblock,
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
      title: blocked ? context.l10n.unblockContact : context.l10n.blockContact,
      titleWidget: Text(
        blocked ? context.l10n.unblockContact : context.l10n.blockContact,
        style: TextStyle(color: blocked ? tokens.danger : null),
      ),
      subtitle: blocked
          ? context.l10n.tapToAllowMessagesAndCallsAgain
          : context.l10n.stopMessagesCallsAndProfileUpdates,
      onTap: blocked ? _confirmUnblock : _confirmBlock,
    );
  }
}
