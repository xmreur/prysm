import 'package:flutter/material.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

class MessageComposer extends StatefulWidget {
  final Function(String) onSendText;
  final VoidCallback onSendImage;
  final VoidCallback onSendFile;

  const MessageComposer({
    Key? key,
    required this.onSendText,
    required this.onSendImage,
    required this.onSendFile,
  }) : super(key: key);

  @override
  _MessageComposerState createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final TextEditingController _textController = TextEditingController();
  String currentText = '';
  bool showEmojiPicker = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _handleSend() {
    final text = currentText.trim();
    if (text.isEmpty) return;
    widget.onSendText(text);
    _textController.clear();
    setState(() {
      currentText = '';
      showEmojiPicker = false;
    });
  }

  void _onEmojiSelected(Category? category, Emoji emoji) {
    final text = _textController.text;
    final cursorPos = _textController.selection.base.offset;
    final newText = cursorPos >= 0
        ? text.substring(0, cursorPos) + emoji.emoji + text.substring(cursorPos)
        : text + emoji.emoji;

    _textController.text = newText;
    _textController.selection = TextSelection.collapsed(offset: (cursorPos >= 0 ? cursorPos : newText.length) + emoji.emoji.length);
    setState(() {
      currentText = newText;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showEmojiPicker)
          SizedBox(
            height: 250,
            child: EmojiPicker(
              onEmojiSelected: _onEmojiSelected,
              config: Config(),
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          color: theme.scaffoldBackgroundColor,
          child: Row(
            children: [
              PopupMenuButton<String>(
                icon: Icon(Icons.drive_folder_upload, color: theme.iconTheme.color),
                onSelected: (value) {
                  if (value == "image") widget.onSendImage();
                  if (value == "file") widget.onSendFile();
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'image',
                    child: Row(
                      children: [
                        Icon(Icons.image),
                        SizedBox(width: 8),
                        Text("Upload Image"),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'file',
                    child: Row(
                      children: [
                        Icon(Icons.attach_file),
                        SizedBox(width: 8),
                        Text("Upload File"),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _textController,
                  onChanged: (text) => setState(() => currentText = text),
                  onSubmitted: (_) => _handleSend(),
                  decoration: InputDecoration(
                    hintText: 'Type a message',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  minLines: 1,
                  maxLines: 5,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.emoji_emotions_outlined,
                color: theme.iconTheme.color),
                onPressed: () {
                  setState(() {
                    showEmojiPicker = !showEmojiPicker;
                    if (showEmojiPicker) {
                      FocusScope.of(context).unfocus(); // Hide keyboard when emoji picker shown
                    }
                  });
                },
              ),
              IconButton(
                icon: Icon(
                  Icons.send,
                  color: currentText.trim().isEmpty ? Colors.grey : theme.iconTheme.color,
                ),
                onPressed: currentText.trim().isEmpty ? null : _handleSend,
              ),
            ],
          ),
        )
      ],
    );
    
  }
}