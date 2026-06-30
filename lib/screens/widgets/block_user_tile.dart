import 'package:flutter/material.dart';
import 'package:prysm/services/block_service.dart';

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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Block contact'),
        content: const Text(
          'You will no longer receive messages, calls, or profile updates from this contact.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Block', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await BlockService.instance.block(widget.peerId);
    widget.onBlocked?.call();
    _refresh();
  }

  Future<void> _confirmUnblock() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unblock contact'),
        content: const Text(
          'This contact will be able to message and call you again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unblock'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await BlockService.instance.unblock(widget.peerId);
    widget.onUnblocked?.call();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final blocked = BlockService.instance.isBlocked(widget.peerId);

    return ListTile(
      leading: Icon(
        blocked ? Icons.block : Icons.block_outlined,
        color: blocked ? Colors.red : null,
      ),
      title: Text(
        blocked ? 'Unblock contact' : 'Block contact',
        style: TextStyle(color: blocked ? Colors.red : null),
      ),
      subtitle: Text(
        blocked
            ? 'Tap to allow messages and calls again'
            : 'Stop messages, calls, and profile updates',
      ),
      onTap: blocked ? _confirmUnblock : _confirmBlock,
    );
  }
}
