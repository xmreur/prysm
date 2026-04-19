import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/material.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

class MessageComposer extends StatefulWidget {
  final Function(String) onSendText;
  final VoidCallback onSendImage;
  final VoidCallback onSendFile;
  final Function(Uint8List bytes, int durationMs)? onSendVoice;

  const MessageComposer({
    super.key,
    required this.onSendText,
    required this.onSendImage,
    required this.onSendFile,
    this.onSendVoice,
  });

  @override
  _MessageComposerState createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final TextEditingController _textController = TextEditingController();
  String currentText = '';
  bool showEmojiPicker = false;

  // Voice recording state
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  Duration _recordDuration = Duration.zero;
  Timer? _recordTimer;
  String? _recordPath;

  @override
  void dispose() {
    _textController.dispose();
    _recordTimer?.cancel();
    _recorder.dispose();
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
    _textController.selection = TextSelection.collapsed(
      offset:
          (cursorPos >= 0 ? cursorPos : newText.length) + emoji.emoji.length,
    );
    setState(() {
      currentText = newText;
    });
  }

  Future<void> _startRecording() async {
    // Only request permission on mobile — desktop has no permission system
    if (Platform.isAndroid || Platform.isIOS) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission denied')),
          );
        }
        return;
      }
    }

    final dir = await getTemporaryDirectory();
    _recordPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: _recordPath!,
    );

    setState(() {
      _isRecording = true;
      _recordDuration = Duration.zero;
    });

    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _recordDuration += const Duration(seconds: 1));
      }
    });
  }

  Future<void> _stopAndSendRecording() async {
    _recordTimer?.cancel();

    final path = await _recorder.stop();
    final durationMs = _recordDuration.inMilliseconds;

    setState(() => _isRecording = false);

    if (path == null || durationMs < 500) {
      // Too short, discard
      if (path != null) File(path).deleteSync();
      return;
    }

    final file = File(path);
    if (!await file.exists()) return;

    final bytes = await file.readAsBytes();
    await file.delete();

    widget.onSendVoice?.call(bytes, durationMs);
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
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
          child: _isRecording ? _buildRecordingRow(theme) : _buildNormalRow(theme),
        ),
      ],
    );
  }

  Widget _buildRecordingRow(ThemeData theme) {
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.delete_outline, color: Colors.red[400]),
          onPressed: _cancelRecording,
        ),
        const SizedBox(width: 8),
        Icon(Icons.fiber_manual_record, color: Colors.red, size: 12),
        const SizedBox(width: 8),
        Text(
          _formatDuration(_recordDuration),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const Spacer(),
        Text(
          'Recording...',
          style: TextStyle(
            color: theme.colorScheme.onSurface.withAlpha(150),
            fontSize: 14,
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          icon: Icon(Icons.send_rounded, color: theme.colorScheme.primary),
          onPressed: _stopAndSendRecording,
        ),
      ],
    );
  }

  Widget _buildNormalRow(ThemeData theme) {
    return Row(
      children: [
        PopupMenuButton<String>(
          icon: Icon(
            Icons.drive_folder_upload,
            color: theme.iconTheme.color,
          ),
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
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
            ),
            minLines: 1,
            maxLines: 5,
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: Icon(
            Icons.emoji_emotions_outlined,
            color: theme.iconTheme.color,
          ),
          onPressed: () {
            setState(() {
              showEmojiPicker = !showEmojiPicker;
              if (showEmojiPicker) {
                FocusScope.of(context).unfocus();
              }
            });
          },
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
          child: currentText.trim().isEmpty
              ? GestureDetector(
                  key: const ValueKey('mic'),
                  onLongPressStart: (_) => _startRecording(),
                  child: IconButton(
                    icon: Icon(
                      Icons.mic_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Hold to record a voice message'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                )
              : IconButton(
                  key: const ValueKey('send'),
                  icon: Icon(
                    Icons.send_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  onPressed: _handleSend,
                ),
        ),
      ],
    );
  }
}
