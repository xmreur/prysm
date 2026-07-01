import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/services/detached_chat_host.dart';

/// Tracks open pop-out chat windows and deduplicates by conversation id.
class DetachedChatWindowRegistry {
  DetachedChatWindowRegistry._() {
    onWindowsChanged.listen((_) => _syncWindows());
  }

  static final DetachedChatWindowRegistry instance = DetachedChatWindowRegistry._();

  final Map<String, String> _conversationToWindowId = {};

  bool get canOpen => _canOpen;
  bool _canOpen = true;

  void setCanOpen(bool value) {
    _canOpen = value;
  }

  bool isOpen(String conversationId) =>
      _conversationToWindowId.containsKey(conversationId);

  Future<void> openOrFocus(DetachedChatLaunch launch) async {
    if (!_canOpen) {
      throw StateError('Detached chat windows are unavailable');
    }

    final existingId = _conversationToWindowId[launch.conversationId];
    if (existingId != null) {
      try {
        final existing = WindowController.fromWindowId(existingId);
        await existing.show();
        try {
          await existing.invokeMethod('focus');
        } catch (_) {}
        return;
      } catch (_) {
        _conversationToWindowId.remove(launch.conversationId);
      }
    }

    final controller = await WindowController.create(
      WindowConfiguration(
        hiddenAtLaunch: true,
        arguments: launch.toArguments(),
      ),
    );

    _conversationToWindowId[launch.conversationId] = controller.windowId;
    DetachedChatHost.instance.registerWindow(
      windowId: controller.windowId,
      launch: launch,
    );

    await controller.show();
  }

  Future<void> _syncWindows() async {
    final controllers = await WindowController.getAll();
    final liveIds = controllers.map((c) => c.windowId).toSet();
    final stale = _conversationToWindowId.entries
        .where((e) => !liveIds.contains(e.value))
        .map((e) => e.key)
        .toList();
    for (final conversationId in stale) {
      final windowId = _conversationToWindowId.remove(conversationId);
      if (windowId != null) {
        DetachedChatHost.instance.unregisterWindow(windowId);
      }
    }
  }

  Future<void> closeAll() async {
    final controllers = await WindowController.getAll();
    final mainId = (await WindowController.fromCurrentEngine()).windowId;
    for (final controller in controllers) {
      if (controller.windowId == mainId) continue;
      try {
        await controller.invokeMethod('mainClosing');
      } catch (_) {}
    }
    _conversationToWindowId.clear();
  }
}
