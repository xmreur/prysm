import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer, size: 16, color: Colors.white70),
            SizedBox(width: 6),
            Text(
              'View Once',
              style: TextStyle(fontSize: 16, color: Colors.white70),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.memory(widget.imageBytes),
        ),
      ),
    );
  }
}
