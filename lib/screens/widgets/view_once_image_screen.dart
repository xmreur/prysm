import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/prysm_scaffold.dart';

/// Full-screen view-once image viewer with screenshot blocking on Android.
class ViewOnceImageScreen extends StatefulWidget {
  final Uint8List imageBytes;

  const ViewOnceImageScreen({required this.imageBytes, super.key});

  @override
  State<ViewOnceImageScreen> createState() => _ViewOnceImageScreenState();
}

class _ViewOnceImageScreenState extends State<ViewOnceImageScreen> {
  static const _flagSecureChannel = MethodChannel('prysm/flag_secure');

  @override
  void initState() {
    super.initState();
    _enableScreenshotPrevention();
  }

  @override
  void dispose() {
    _disableScreenshotPrevention();
    super.dispose();
  }

  Future<void> _enableScreenshotPrevention() async {
    if (Platform.isAndroid) {
      try {
        await _flagSecureChannel.invokeMethod('enable');
      } catch (_) {}
    }
  }

  Future<void> _disableScreenshotPrevention() async {
    if (Platform.isAndroid) {
      try {
        await _flagSecureChannel.invokeMethod('disable');
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return PrysmPage(
      backgroundColor: const Color(0xFF000000),
      title: 'View once',
      leading: PrysmIconButton(
        icon: PrysmIcons.close,
        color: const Color(0xFFFFFFFF),
        onPressed: () => Navigator.of(context).pop(),
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.memory(widget.imageBytes),
        ),
      ),
    );
  }
}
