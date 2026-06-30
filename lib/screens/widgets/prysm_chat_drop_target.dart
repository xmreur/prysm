import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:prysm/util/desktop_platform.dart';

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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Only one file at a time')),
          );
        }

        final file = detail.files.first;
        final path = file.path;
        if (path.isEmpty) return;

        final messenger = ScaffoldMessenger.of(context);
        if (await FileSystemEntity.type(path) == FileSystemEntityType.directory) {
          messenger.showSnackBar(
            const SnackBar(content: Text('Folders can\'t be sent')),
          );
          return;
        }

        final name = file.name.isNotEmpty ? file.name : path.split(Platform.pathSeparator).last;
        await widget.onFileDropped(path, name);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_dragging)
            IgnorePointer(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.upload_file,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Drop to send',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
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
