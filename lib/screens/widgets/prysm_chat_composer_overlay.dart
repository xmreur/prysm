import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:provider/provider.dart';
import 'package:prysm/screens/message_composer.dart';

/// Bottom overlay composer for [Chat], reporting height to [ComposerHeightNotifier].
class PrysmChatComposerOverlay extends StatefulWidget {
  final Widget? replyPreview;
  final void Function(String) onSendText;
  final VoidCallback onSendImage;
  final VoidCallback onSendFile;
  final void Function(Uint8List bytes, int durationMs)? onSendVoice;

  const PrysmChatComposerOverlay({
    super.key,
    this.replyPreview,
    required this.onSendText,
    required this.onSendImage,
    required this.onSendFile,
    this.onSendVoice,
  });

  @override
  State<PrysmChatComposerOverlay> createState() =>
      _PrysmChatComposerOverlayState();
}

class _PrysmChatComposerOverlayState extends State<PrysmChatComposerOverlay> {
  final GlobalKey _measureKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant PrysmChatComposerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replyPreview != widget.replyPreview) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
  }

  void _measure() {
    if (!mounted) return;

    final renderBox =
        _measureKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final height = renderBox.size.height;
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;
    context.read<ComposerHeightNotifier>().setHeight(height - bottomSafeArea);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: KeyedSubtree(
        key: _measureKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.replyPreview != null) widget.replyPreview!,
            MessageComposer(
              onSendText: widget.onSendText,
              onSendImage: widget.onSendImage,
              onSendFile: widget.onSendFile,
              onSendVoice: widget.onSendVoice,
              onLayoutChanged: _measure,
            ),
          ],
        ),
      ),
    );
  }
}
