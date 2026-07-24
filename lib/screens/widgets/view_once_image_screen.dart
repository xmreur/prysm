import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/prysm_scaffold.dart';

/// Single viewer shared by the DM, group and self chat screens (Fase 6C —
/// replaces the three screen-local `_ViewOnceScreen`/`_GroupViewOnceScreen`
/// copies). Auto-mark-viewed and content wipe stay in the caller, which
/// awaits `Navigator.push` and then persists `markViewOnceViewed`.
class ViewOnceImageScreen extends StatefulWidget {
  final Uint8List imageBytes;

  /// Optional fit for the image. The self-chat copy used `BoxFit.contain`;
  /// the DM/group copies (and the media gallery) used the default — both
  /// preserved via this knob rather than silently unified.
  final BoxFit? fit;

  /// App bar title. Each pre-unification screen differed: the DM viewer
  /// showed 'View Once', the group/self viewers showed none at all (null
  /// collapses `PrysmPage`'s header to a bare `Spacer`), and the media
  /// gallery's viewer showed 'View once'. Defaults to the gallery's value
  /// so its only call site — which passes no override — stays unchanged.
  final String? title;

  /// Close (X) icon color. The DM/group/self viewers all used a ~70%
  /// translucent white (`0xB3FFFFFF`); the media gallery's viewer used
  /// full opacity, kept here as the default for that unmodified call site.
  final Color closeColor;

  const ViewOnceImageScreen({
    required this.imageBytes,
    this.fit,
    this.title = 'View once',
    this.closeColor = const Color(0xFFFFFFFF),
    super.key,
  });

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
      title: widget.title,
      leading: PrysmIconButton(
        icon: PrysmIcons.close,
        color: widget.closeColor,
        onPressed: () => Navigator.of(context).pop(),
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.memory(widget.imageBytes, fit: widget.fit),
        ),
      ),
    );
  }
}
