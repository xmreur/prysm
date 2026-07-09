import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/util/detached_message_codec.dart';
import 'package:prysm/util/inbound_message_notifier.dart';

typedef DetachedDecryptRowsFn = Future<List<Message>> Function(
  DetachedChatKind chatKind,
  String conversationId,
  List<Map<String, dynamic>> rows,
);

typedef DetachedSendTextFn = Future<String?> Function({
  required DetachedChatKind chatKind,
  required String conversationId,
  required String text,
  String? replyToId,
  required String messageId,
});

typedef DetachedSendFileFn = Future<String?> Function({
  required DetachedChatKind chatKind,
  required String conversationId,
  required Uint8List bytes,
  required String fileName,
  required String type,
  String? replyToId,
  required String messageId,
  bool viewOnce,
});

typedef DetachedSendVoiceFn = Future<String?> Function({
  required DetachedChatKind chatKind,
  required String conversationId,
  required Uint8List bytes,
  required int durationMs,
  required String messageId,
});

/// Main-window IPC host for pop-out chat windows.
class DetachedChatHost {
  DetachedChatHost._();

  static final DetachedChatHost instance = DetachedChatHost._();

  static const _hostChannelName = 'prysm/detached_chat_host';

  final _hostChannel = const WindowMethodChannel(
    _hostChannelName,
    mode: ChannelMode.unidirectional,
  );

  final Map<String, String> _conversationIdByWindowId = {};
  final Map<String, DetachedChatKind> _kindByWindowId = {};

  DetachedDecryptRowsFn? decryptRows;
  DetachedSendTextFn? sendText;
  DetachedSendFileFn? sendFile;
  DetachedSendVoiceFn? sendVoice;

  StreamSubscription<InboundMessageEvent>? _inboundSub;
  bool _started = false;

  void registerWindow({
    required String windowId,
    required DetachedChatLaunch launch,
  }) {
    _conversationIdByWindowId[windowId] = launch.conversationId;
    _kindByWindowId[windowId] = launch.chatKind!;
  }

  void unregisterWindow(String windowId) {
    _conversationIdByWindowId.remove(windowId);
    _kindByWindowId.remove(windowId);
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;

    await _hostChannel.setMethodCallHandler(_handleCall);
    _inboundSub ??= InboundMessageNotifier.instance.onInboundMessage.listen(
      _forwardInbound,
    );
  }

  Future<void> stop() async {
    await _hostChannel.setMethodCallHandler(null);
    await _inboundSub?.cancel();
    _inboundSub = null;
    _started = false;
    _conversationIdByWindowId.clear();
    _kindByWindowId.clear();
  }

  Future<void> notifyMainClosing() async {
    final controllers = await WindowController.getAll();
    for (final controller in controllers) {
      if (controller.windowId == (await WindowController.fromCurrentEngine()).windowId) {
        continue;
      }
      try {
        await controller.invokeMethod('mainClosing');
      } catch (_) {}
    }
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    try {
      return await _handleCallImpl(call);
    } catch (e, st) {
      debugPrint('DetachedChatHost: ${call.method} failed: $e\n$st');
      return null;
    }
  }

  Future<dynamic> _handleCallImpl(MethodCall call) async {
    switch (call.method) {
      case 'ping':
        return true;
      case 'decryptRows':
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        final kind = _parseChatKind(args['chatKind'] as String?);
        if (kind == null) return [];
        final conversationId = args['conversationId'] as String;
        final rows = (args['rows'] as List<dynamic>)
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        final decrypt = decryptRows;
        if (decrypt == null) return [];
        final messages = await decrypt(kind, conversationId, rows);
        return DetachedMessageCodec.encodeAll(messages);
      case 'sendText':
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        final send = sendText;
        if (send == null) return null;
        return send(
          chatKind: _parseChatKind(args['chatKind'] as String?) ?? DetachedChatKind.direct,
          conversationId: args['conversationId'] as String,
          text: args['text'] as String,
          replyToId: args['replyToId'] as String?,
          messageId: args['messageId'] as String,
        );
      case 'sendFile':
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        final sendFn = sendFile;
        if (sendFn == null) return null;
        return sendFn(
          chatKind: _parseChatKind(args['chatKind'] as String?) ?? DetachedChatKind.direct,
          conversationId: args['conversationId'] as String,
          bytes: args['bytes'] as Uint8List,
          fileName: args['fileName'] as String,
          type: args['type'] as String,
          replyToId: args['replyToId'] as String?,
          messageId: args['messageId'] as String,
          viewOnce: args['viewOnce'] as bool? ?? false,
        );
      case 'sendVoice':
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        final sendFn = sendVoice;
        if (sendFn == null) return null;
        return sendFn(
          chatKind: _parseChatKind(args['chatKind'] as String?) ?? DetachedChatKind.direct,
          conversationId: args['conversationId'] as String,
          bytes: args['bytes'] as Uint8List,
          durationMs: args['durationMs'] as int,
          messageId: args['messageId'] as String,
        );
      default:
        throw MissingPluginException('Unknown method ${call.method}');
    }
  }

  Future<void> _forwardInbound(InboundMessageEvent event) async {
    final targets = <String, String>{};
    for (final entry in _conversationIdByWindowId.entries) {
      targets[entry.key] = entry.value;
    }
    if (targets.isEmpty) return;

    for (final entry in targets.entries) {
      final windowId = entry.key;
      final conversationId = entry.value;
      final kind = _kindByWindowId[windowId];
      if (kind == null) continue;

      final matches = switch (kind) {
        DetachedChatKind.direct =>
          event.groupId == null && (event.senderId == conversationId || event.receiverId == conversationId),
        DetachedChatKind.group => event.groupId == conversationId,
        DetachedChatKind.self =>
          event.groupId == null &&
              event.senderId == conversationId &&
              event.receiverId == conversationId,
      };
      if (!matches) continue;

      try {
        final controller = WindowController.fromWindowId(windowId);
        await controller.invokeMethod(
          'inboundMessage',
          [DetachedMessageCodec.encode(await _rowToMessage(event.row, kind, conversationId))],
        );
      } catch (e) {
        debugPrint('DetachedChatHost: forward inbound failed: $e');
      }
    }
  }

  Future<Message> _rowToMessage(
    Map<String, dynamic> row,
    DetachedChatKind kind,
    String conversationId,
  ) async {
    final decrypt = decryptRows;
    if (decrypt == null) {
      throw StateError('DetachedChatHost decryptRows not configured');
    }
    final messages = await decrypt(kind, conversationId, [row]);
    if (messages.isEmpty) {
      throw StateError('Failed to decrypt inbound row');
    }
    return messages.first;
  }

  DetachedChatKind? _parseChatKind(String? raw) {
    if (raw == null) return null;
    try {
      return DetachedChatKind.values.byName(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> forwardMessageStatus({
    required DetachedChatKind kind,
    required String conversationId,
    required String messageId,
    required String status,
  }) async {
    for (final entry in _conversationIdByWindowId.entries) {
      if (entry.value != conversationId) continue;
      if (_kindByWindowId[entry.key] != kind) continue;
      try {
        final controller = WindowController.fromWindowId(entry.key);
        await controller.invokeMethod('messageStatus', {
          'messageId': messageId,
          'status': status,
        });
      } catch (e) {
        debugPrint('DetachedChatHost: forward status failed: $e');
      }
    }
  }
}
