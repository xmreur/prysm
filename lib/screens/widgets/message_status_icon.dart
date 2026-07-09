import 'package:flutter/widgets.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/util/message_status_mapper.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

/// Overlapping checkmarks (Telegram-style read receipt).
class PrysmDoubleCheckIcon extends StatelessWidget {
  const PrysmDoubleCheckIcon({
    required this.size,
    required this.color,
    super.key,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final offset = size * 0.42;
    return SizedBox(
      width: size + offset,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Icon(PrysmIcons.done, size: size, color: color),
          ),
          Positioned(
            left: offset,
            top: 0,
            child: Icon(PrysmIcons.done, size: size, color: color),
          ),
        ],
      ),
    );
  }
}

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

  static const _iconSize = 14.0;

  @override
  Widget build(BuildContext context) {
    if (!isSentByMe) return const SizedBox.shrink();

    final state = outboundTickState(
      message,
      readReceiptsEnabled: readReceiptsEnabled,
    );

    return switch (state) {
      OutboundTickState.failed => GestureDetector(
          onTap: onRetry,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                PrysmIcons.warningAmberRounded,
                size: _iconSize,
                color: context.prysmStyle.tokens.danger,
              ),
              const SizedBox(width: 2),
              Text(
                'Tap to retry',
                style: TextStyle(
                  fontSize: 9,
                  color: context.prysmStyle.tokens.danger,
                ),
              ),
            ],
          ),
        ),
      OutboundTickState.pending => Icon(
          PrysmIcons.schedule,
          size: _iconSize,
          color: tickColor,
        ),
      OutboundTickState.delivered => Icon(
          PrysmIcons.done,
          size: _iconSize,
          color: tickColor,
        ),
      OutboundTickState.read => PrysmDoubleCheckIcon(
          size: _iconSize,
          color: tickColor,
        ),
    };
  }
}
