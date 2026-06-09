import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Preview picked image before sending, with optional view-once toggle.
class ImageSendPreviewScreen extends StatefulWidget {
  final Uint8List bytes;

  const ImageSendPreviewScreen({
    required this.bytes,
    super.key,
  });

  /// Returns view-once flag when sent, or null if cancelled.
  static Future<bool?> open(BuildContext context, Uint8List bytes) {
    return Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => ImageSendPreviewScreen(bytes: bytes),
      ),
    );
  }

  @override
  State<ImageSendPreviewScreen> createState() => _ImageSendPreviewScreenState();
}

class _ImageSendPreviewScreenState extends State<ImageSendPreviewScreen> {
  bool _viewOnce = false;

  void _send() => Navigator.pop(context, _viewOnce);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('Send photo'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4,
                child: Image.memory(
                  widget.bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          Material(
            elevation: 8,
            color: theme.colorScheme.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: Icon(
                        Icons.visibility_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      title: const Text('View once'),
                      subtitle: const Text(
                        'Photo disappears after the recipient opens it',
                      ),
                      value: _viewOnce,
                      onChanged: (value) => setState(() => _viewOnce = value),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _send,
                      icon: const Icon(Icons.send),
                      label: Text(_viewOnce ? 'Send view once' : 'Send photo'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
