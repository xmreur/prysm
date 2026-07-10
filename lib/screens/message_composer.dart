import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_text_field.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/services.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:prysm/ui/core/emoji_search_wrapper.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/services/message_draft_store.dart';
import 'package:prysm/theme/prysm_theme.dart';
import 'package:prysm/theme/prysm_tokens.dart';
import 'package:prysm/util/desktop_platform.dart';
import 'package:prysm/util/waveform_extractor.dart';

class MessageComposer extends StatefulWidget {
  final Function(String) onSendText;
  final VoidCallback onSendImage;
  final VoidCallback onSendFile;
  final Function(Uint8List bytes, int durationMs)? onSendVoice;
  final ValueChanged<bool>? onTypingChanged;
  final VoidCallback? onLayoutChanged;
  final String? draftKey;

  const MessageComposer({
    super.key,
    required this.onSendText,
    required this.onSendImage,
    required this.onSendFile,
    this.onSendVoice,
    this.onTypingChanged,
    this.onLayoutChanged,
    this.draftKey,
  });

  @override
  State<MessageComposer> createState() => MessageComposerState();
}

class MessageComposerState extends State<MessageComposer> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  String currentText = '';
  bool showEmojiPicker = false;

  // Voice recording state
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  Duration _recordDuration = Duration.zero;
  Timer? _recordTimer;
  String? _recordPath;

  @override
  void initState() {
    super.initState();
    _loadDraft();
    if (isDesktopPlatform) {
      HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _notifyLayoutChanged());
  }

  @override
  void didUpdateWidget(covariant MessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draftKey != widget.draftKey) {
      _persistDraft(oldWidget.draftKey);
      _loadDraft();
    }
  }

  void _loadDraft() {
    final key = widget.draftKey;
    if (key == null || key.isEmpty) return;
    final text = MessageDraftStore.instance.get(key).text;
    if (text.isEmpty) return;
    _textController.text = text;
    currentText = text;
  }

  void _persistDraft([String? keyOverride]) {
    final key = keyOverride ?? widget.draftKey;
    if (key == null || key.isEmpty) return;
    MessageDraftStore.instance.setText(key, _textController.text);
  }

  @override
  void dispose() {
    widget.onTypingChanged?.call(false);
    _persistDraft();
    if (isDesktopPlatform) {
      HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    }
    _textController.dispose();
    _inputFocusNode.dispose();
    _recordTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  void _notifyLayoutChanged() {
    widget.onLayoutChanged?.call();
  }

  void _notifyTypingFromText(String text) {
    widget.onTypingChanged?.call(text.trim().isNotEmpty);
  }

  void _handleSend() {
    final text = currentText.trim();
    if (text.isEmpty) return;
    widget.onSendText(text);
    widget.onTypingChanged?.call(false);
    _textController.clear();
    setState(() {
      currentText = '';
      showEmojiPicker = false;
    });
    _persistDraft();
    WidgetsBinding.instance.addPostFrameCallback((_) => _notifyLayoutChanged());
  }

  void _insertNewlineAtSelection() {
    final text = _textController.text;
    final sel = _textController.selection;
    final start = sel.start >= 0 ? sel.start : text.length;
    final end = sel.end >= 0 ? sel.end : text.length;
    final newText = text.replaceRange(start, end, '\n');
    _textController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + 1),
    );
    setState(() => currentText = newText);
    _persistDraft();
    _notifyTypingFromText(newText);
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!_inputFocusNode.hasFocus) return false;
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.enter) return false;

    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      _insertNewlineAtSelection();
      return true;
    }

    _handleSend();
    return true;
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
    _persistDraft();
    _notifyTypingFromText(newText);
  }

  void _showAttachmentSheet() {
    final tokens = context.prysmTokens;
    showPrysmSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PrysmListRow(
            leading: Icon(PrysmIcons.image, color: tokens.textSecondary),
            title: 'Upload Image',
            onTap: () {
              Navigator.pop(ctx);
              widget.onSendImage();
            },
          ),
          PrysmListRow(
            leading: Icon(PrysmIcons.attach, color: tokens.textSecondary),
            title: 'Upload File',
            onTap: () {
              Navigator.pop(ctx);
              widget.onSendFile();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _startRecording() async {
    // Only request permission on mobile — desktop has no permission system
    if (Platform.isAndroid || Platform.isIOS) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        if (mounted) {
          showPrysmToast(context, 'Microphone permission denied');
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

    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _recordDuration = Duration.zero;
    });
    widget.onTypingChanged?.call(false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _notifyLayoutChanged());

    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _recordDuration += const Duration(seconds: 1));
      }
    });
  }

  Future<void> _stopAndSendRecording() async {
    _recordTimer?.cancel();

    final path = await _recorder.stop();

    if (!mounted) return;
    setState(() => _isRecording = false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _notifyLayoutChanged());

    if (path == null) {
      return;
    }

    final file = File(path);
    if (!await file.exists()) return;

    final bytes = await file.readAsBytes();
    await file.delete();

    final durationMs = WaveformExtractor.estimateDurationMs(bytes);
    if (durationMs < 500) {
      return;
    }

    widget.onSendVoice?.call(bytes, durationMs);
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _notifyLayoutChanged());
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
    final tokens = context.prysmTokens;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showEmojiPicker)
          EmojiSearchWrapper(
            onEmojiSelected: (emoji) => _onEmojiSelected(null, Emoji(emoji, '')),
          ),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: PrysmTokens.spacing8,
            vertical: PrysmTokens.spacing8,
          ),
          color: tokens.composer,
          child: _isRecording
              ? _buildRecordingRow(tokens)
              : _buildNormalRow(tokens),
        ),
      ],
    );
  }

  Widget _buildRecordingRow(PrysmTokens tokens) {
    return Row(
      children: [
        PrysmIconButton(
          icon: PrysmIcons.deleteOutline,
          color: tokens.danger,
          onPressed: _cancelRecording,
        ),
        const SizedBox(width: 8),
        Icon(PrysmIcons.offlineBolt, color: tokens.danger, size: 12),
        const SizedBox(width: 8),
        Text(
          _formatDuration(_recordDuration),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: tokens.textPrimary,
          ),
        ),
        const Spacer(),
        Text(
          'Recording...',
          style: TextStyle(color: tokens.textMuted, fontSize: 14),
        ),
        const SizedBox(width: 12),
        PrysmIconButton(
          icon: PrysmIcons.send,
          color: tokens.accent,
          onPressed: _stopAndSendRecording,
        ),
      ],
    );
  }

  Widget _buildNormalRow(PrysmTokens tokens) {
    return Row(
      children: [
        PrysmIconButton(
          icon: PrysmIcons.addCircle,
          color: tokens.textSecondary,
          onPressed: _showAttachmentSheet,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: PrysmTextField(
            focusNode: _inputFocusNode,
            controller: _textController,
            hintText: 'Message',
            onChanged: (text) {
              setState(() => currentText = text);
              _persistDraft();
              _notifyTypingFromText(text);
            },
            onSubmitted: isDesktopPlatform ? null : (_) => _handleSend(),
          ),
        ),
        const SizedBox(width: 8),
        PrysmIconButton(
          icon: PrysmIcons.emoji,
          color: tokens.textSecondary,
          onPressed: () {
            setState(() {
              showEmojiPicker = !showEmojiPicker;
              if (showEmojiPicker) {
                FocusScope.of(context).unfocus();
              }
            });
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _notifyLayoutChanged(),
            );
          },
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: currentText.trim().isEmpty
              ? PrysmIconButton(
                  key: const ValueKey('mic'),
                  icon: PrysmIcons.micOutlined,
                  color: tokens.accent,
                  onPressed: () {
                    showPrysmToast(
                      context,
                      'Hold to record a voice message',
                    );
                  },
                  onLongPressStart: (_) => _startRecording(),
                )
              : PrysmIconButton(
                  key: const ValueKey('send'),
                  icon: PrysmIcons.send,
                  color: tokens.accent,
                  onPressed: _handleSend,
                ),
        ),
      ],
    );
  }
}
