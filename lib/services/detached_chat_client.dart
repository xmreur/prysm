import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/models/detached_chat_launch.dart';
import 'package:prysm/util/detached_message_codec.dart';
import 'package:prysm/util/logging.dart';
import 'package:window_manager/window_manager.dart';

/// IPC client used by pop-out chat windows to talk to the main window.
class DetachedChatClient {
  DetachedChatClient({
    required this.launch,
    required this.windowId,
  });

  final DetachedChatLaunch launch;
  final String windowId;

  static const _hostChannelName = 'prysm/detached_chat_host';

  final _hostChannel = const WindowMethodChannel(
    _hostChannelName,
    mode: ChannelMode.unidirectional,
  );

  final _inboundController = StreamController<List<Message>>.broadcast();
  final _statusController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<List<Message>> get onInboundMessages => _inboundController.stream;
  Stream<Map<String, dynamic>> get onStatusUpdates => _statusController.stream;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final controller = await WindowController.fromCurrentEngine();
    await controller.setWindowMethodHandler(_handleHostPush);

    final ok = await ping();
    if (!ok) {
      Logging.error('Main window not reachable', 'DetachedChatClient');
    }
  }

  Future<bool> ping() async {
    try {
      final result = await _hostChannel.invokeMethod<bool>('ping');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Message>> decryptRows(List<Map<String, dynamic>> rows) async {
    final result = await _hostChannel.invokeMethod<List<dynamic>>(
      'decryptRows',
      {
        'chatKind': launch.chatKind!.name,
        'conversationId': launch.conversationId,
        'rows': rows,
      },
    );
    if (result == null) return const [];
    return DetachedMessageCodec.decodeAll(result);
  }

  Future<String?> sendText({
    required String text,
    String? replyToId,
    required String messageId,
  }) async {
    return _hostChannel.invokeMethod<String>(
      'sendText',
      {
        'chatKind': launch.chatKind!.name,
        'conversationId': launch.conversationId,
        'text': text,
        'replyToId': replyToId,
        'messageId': messageId,
      },
    );
  }

  Future<String?> sendFile({
    required Uint8List bytes,
    required String fileName,
    required String type,
    String? replyToId,
    required String messageId,
    bool viewOnce = false,
  }) async {
    return _hostChannel.invokeMethod<String>(
      'sendFile',
      {
        'chatKind': launch.chatKind!.name,
        'conversationId': launch.conversationId,
        'fileName': fileName,
        'type': type,
        'replyToId': replyToId,
        'messageId': messageId,
        'viewOnce': viewOnce,
        'bytes': bytes,
      },
    );
  }

  Future<String?> sendVoice({
    required Uint8List bytes,
    required int durationMs,
    required String messageId,
  }) async {
    return _hostChannel.invokeMethod<String>(
      'sendVoice',
      {
        'chatKind': launch.chatKind!.name,
        'conversationId': launch.conversationId,
        'durationMs': durationMs,
        'messageId': messageId,
        'bytes': bytes,
      },
    );
  }

  Future<dynamic> _handleHostPush(MethodCall call) async {
    switch (call.method) {
      case 'mainClosing':
        unawaited(windowManager.close());
        return null;
      case 'focus':
        unawaited(windowManager.focus());
        return null;
      case 'inboundMessage':
        final maps = (call.arguments as List<dynamic>?) ?? const [];
        _inboundController.add(DetachedMessageCodec.decodeAll(maps));
        return null;
      case 'messageStatus':
        final payload = (call.arguments as Map?)?.cast<String, dynamic>();
        if (payload != null) {
          _statusController.add(payload);
        }
        return null;
      default:
        throw MissingPluginException('Unknown method ${call.method}');
    }
  }

  void dispose() {
    _inboundController.close();
    _statusController.close();
  }
}
