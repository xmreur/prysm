import 'package:flutter/widgets.dart';
import 'dart:typed_data';

import 'package:prysm/screens/message_composer.dart';
import 'package:prysm/screens/widgets/typing_indicator_bar.dart';
import 'package:prysm/theme/prysm_tokens.dart';

/// Bottom composer column replacing [PrysmChatComposerOverlay].
class PrysmChatComposerColumn extends StatelessWidget {
  const PrysmChatComposerColumn({
    required this.onSendText,
    required this.onSendImage,
    required this.onSendFile,
    this.replyPreview,
    this.typingTypistNames = const [],
    this.onSendVoice,
    this.onTypingChanged,
    this.draftKey,
    this.topBanner,
    super.key,
  });

  final Widget? replyPreview;
  final List<String> typingTypistNames;
  final void Function(String) onSendText;
  final VoidCallback onSendImage;
  final VoidCallback onSendFile;
  final void Function(Uint8List bytes, int durationMs)? onSendVoice;
  final ValueChanged<bool>? onTypingChanged;
  final String? draftKey;
  final Widget? topBanner;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?topBanner,
        ?replyPreview,
        if (typingTypistNames.isNotEmpty)
          TypingIndicatorBar(typistNames: typingTypistNames),
        MessageComposer(
          draftKey: draftKey,
          onSendText: onSendText,
          onSendImage: onSendImage,
          onSendFile: onSendFile,
          onSendVoice: onSendVoice,
          onTypingChanged: onTypingChanged,
        ),
      ],
    );
  }
}

/// Telegram-style bubble corner radii.
BorderRadius prysmBubbleBorderRadius({required bool isSentByMe}) {
  const r = PrysmTokens.radiusBubble;
  const small = 4.0;
  if (isSentByMe) {
    return const BorderRadius.only(
      topLeft: Radius.circular(r),
      topRight: Radius.circular(r),
      bottomLeft: Radius.circular(r),
      bottomRight: Radius.circular(small),
    );
  }
  return const BorderRadius.only(
    topLeft: Radius.circular(r),
    topRight: Radius.circular(r),
    bottomLeft: Radius.circular(small),
    bottomRight: Radius.circular(r),
  );
}
