import 'package:flutter/widgets.dart';
import 'package:prysm/l10n/l10n_extensions.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

/// Italic "Forwarded" caption shown at the top of a bubble.
class MessageForwardedLabel extends StatelessWidget {
  const MessageForwardedLabel({
    this.message,
    this.metadata,
    this.color,
    super.key,
  });

  final Message? message;
  final Map<String, dynamic>? metadata;
  final Color? color;

  bool get _visible =>
      (metadata ?? message?.metadata)?['forwarded'] == true;

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        context.l10n.forwarded,
        style: context.prysmStyle.captionStyle.copyWith(
          fontStyle: FontStyle.italic,
          color: color ?? context.prysmStyle.tokens.textMuted,
        ),
      ),
    );
  }
}
