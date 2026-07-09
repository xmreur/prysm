import 'package:flutter/widgets.dart';
import 'package:prysm/ui/core/prysm_toast.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:prysm/util/desktop_platform.dart';
import 'package:prysm/ui/core/prysm_icons.dart';

/// Desktop-only drop target for sending files into an open chat.
class PrysmChatDropTarget extends StatefulWidget {
  final bool enabled;
  final Future<void> Function(String path, String name) onFileDropped;
  final Widget child;

  const PrysmChatDropTarget({
    super.key,
    this.enabled = true,
    required this.onFileDropped,
    required this.child,
  });

  @override
  State<PrysmChatDropTarget> createState() => _PrysmChatDropTargetState();
}

class _PrysmChatDropTargetState extends State<PrysmChatDropTarget> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform || !widget.enabled) {
      return widget.child;
    }

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) async {
        setState(() => _dragging = false);

        if (detail.files.isEmpty) return;

        if (detail.files.length > 1 && mounted) {
          showPrysmToast(context, 'Only one file at a time');
        }

        final file = detail.files.first;
        final path = file.path;
        if (path.isEmpty) return;

        if (await FileSystemEntity.type(path) == FileSystemEntityType.directory) {
          if (!context.mounted) return;
          showPrysmToast(context, "Folders can't be sent");
          return;
        }

        final name = file.name.isNotEmpty ? file.name : path.split(Platform.pathSeparator).last;
        if (!context.mounted) return;
        await widget.onFileDropped(path, name);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_dragging)
            IgnorePointer(
              child: ColoredBox(
                color: context.prysmStyle.tokens.accent.withValues(alpha: 0.12),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        PrysmIcons.uploadFile,
                        size: 48,
                        color: context.prysmStyle.tokens.accent,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Drop to send',
                        style: context.prysmStyle.titleStyle.copyWith(
                              color: context.prysmStyle.tokens.accent,
                            ),
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
