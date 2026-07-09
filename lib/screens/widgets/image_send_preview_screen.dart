import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'dart:typed_data';
import 'package:prysm/ui/core/prysm_app.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_switch.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/theme/prysm_style_scope.dart';

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
      PrysmPageRoute<bool>(
        page: ImageSendPreviewScreen(bytes: bytes),
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
    final tokens = context.prysmStyle.tokens;

    return PrysmPage(
      title: 'Send photo',
      leading: PrysmIconButton(
        icon: PrysmIcons.close,
        onPressed: () => Navigator.pop(context),
      ),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: tokens.surfaceElevated,
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
          DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surface,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF000000).withValues(alpha: 0.12),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PrysmSwitchRow(
                      title: 'View once',
                      subtitle:
                          'Photo disappears after the recipient opens it',
                      value: _viewOnce,
                      onChanged: (value) => setState(() => _viewOnce = value),
                    ),
                    const SizedBox(height: 8),
                    PrysmButton(
                      label: _viewOnce ? 'Send view once' : 'Send photo',
                      onPressed: _send,
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
