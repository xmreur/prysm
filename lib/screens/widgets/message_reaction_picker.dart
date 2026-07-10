import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_pressable.dart';
import 'package:prysm/ui/core/emoji_search_wrapper.dart';

/// Quick emoji row + optional full picker for message reactions.
class MessageReactionPicker extends StatefulWidget {
  final ValueChanged<String> onEmojiSelected;

  const MessageReactionPicker({
    required this.onEmojiSelected,
    super.key,
  });

  static const quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  @override
  State<MessageReactionPicker> createState() => _MessageReactionPickerState();
}

class _MessageReactionPickerState extends State<MessageReactionPicker> {
  var _showFullPicker = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final emoji in MessageReactionPicker.quickEmojis)
                PrysmPressable(
                  onTap: () => widget.onEmojiSelected(emoji),
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(emoji, style: const TextStyle(fontSize: 26)),
                  ),
                ),
            ],
          ),
        ),
        PrysmTextButton(
          label: _showFullPicker ? 'Hide emoji picker' : 'More reactions…',
          onPressed: () => setState(() => _showFullPicker = !_showFullPicker),
        ),
        if (_showFullPicker)
          EmojiSearchWrapper(
            onEmojiSelected: widget.onEmojiSelected,
          ),
      ],
    );
  }
}

/// Bottom sheet with reaction picker + optional action tiles.
Future<void> showMessageActionsSheet({
  required BuildContext context,
  required ValueChanged<String> onReactionSelected,
  required List<Widget> actionTiles,
}) {
  return showPrysmSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MessageReactionPicker(
            onEmojiSelected: (emoji) {
              Navigator.pop(ctx);
              onReactionSelected(emoji);
            },
          ),
          const PrysmDivider(),
          ...actionTiles,
        ],
      ),
    ),
  );
}
