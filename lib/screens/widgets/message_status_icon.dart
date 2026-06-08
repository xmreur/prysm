import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:prysm/util/message_status_mapper.dart';

/// Tick / clock / failed status for outgoing messages.
class MessageStatusIcon extends StatelessWidget {
  final Message message;
  final bool isSentByMe;
  final Color tickColor;
  final bool readReceiptsEnabled;
  final VoidCallback? onRetry;

  const MessageStatusIcon({
    required this.message,
    required this.isSentByMe,
    required this.tickColor,
    required this.readReceiptsEnabled,
    this.onRetry,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (!isSentByMe) return const SizedBox.shrink();

    final isFailed = message.metadata?['failed'] == true;
    if (isFailed) {
      return GestureDetector(
        onTap: onRetry,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 14, color: Colors.red[400]),
            const SizedBox(width: 2),
            Text(
              'Tap to retry',
              style: TextStyle(fontSize: 9, color: Colors.red[400]),
            ),
          ],
        ),
      );
    }

    final isRead = readReceiptsEnabled && message.seenAt != null;
    if (isRead) {
      return Icon(Icons.done_all, size: 14, color: tickColor);
    }

    if (message.sentAt != null) {
      return Icon(Icons.done, size: 14, color: tickColor.withAlpha(140));
    }

    if (isOutboundPending(message)) {
      return Icon(Icons.schedule, size: 14, color: tickColor.withAlpha(120));
    }

    return const SizedBox.shrink();
  }
}
