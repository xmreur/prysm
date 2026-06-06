import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import '../database/messages.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/conversation_refresh_notifier.dart';
import 'package:prysm/util/peer_profile_cache.dart';

class PrysmServer {
  static PrysmServer? instance;

  final int port;
  final KeyManager keyManager;
  HttpServer? _server;

  final settings = SettingsService();

  /// Set when Tor is ready so group control messages can be processed.
  String? localOnionAddress;

  PrysmServer({this.port = 8080, required this.keyManager}) {
    instance = this;
  }

  Future<void> start() async {
    final handler = Pipeline()
        .addMiddleware(logRequests()) // Auto logs requests
        .addHandler(_requestHandler);

    _server = await io.serve(
      handler,
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );

    print('HTTP server now running on http://127.0.0.1:$port');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    print('HTTP server stopped');
  }

  Future<Response> _requestHandler(Request request) async {
    print('${request.method} - ${request.url}');

    try {
      // POST /message
      if (request.method == 'POST' && request.url.path == 'message') {
        return await _handlePostMessage(request);
      }

      // GET /public (public key - backwards compat)
      if (request.method == 'GET' && request.url.path == 'public') {
        return _handleGetPublicKey();
      }

      // GET /profile (public key + username + avatar)
      if (request.method == 'GET' && request.url.path == 'profile') {
        return _handleGetProfile();
      }

      return Response.notFound(
        jsonEncode({'error': 'Endpoint not found'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e, stack) {
      print('PrysmServer Error: $e\n$stack');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Internal server error'}),
      );
    }
  }

  Future<Response> _handlePostMessage(Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      print('PrysmServer: Received ${data['type']} from ${data['senderId']}');

      final type = data['type'] as String;

      if (!_isValidMessageData(data)) {
        return _badRequest(
          'Missing required fields: id, senderId, receiverId, message, type, timestamp',
        );
      }

      // Group control messages — decrypt and update local group state
      if (isGroupControlType(type)) {
        final receiverId = data['receiverId'] as String;
        if (localOnionAddress != null && receiverId != localOnionAddress) {
          return Response.forbidden(
            jsonEncode({'error': 'Control message not addressed to this node'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        await DBHelper.ensureUserExist(data['senderId'] as String);
        _fetchSenderProfile(data['senderId'] as String);

        final localId = localOnionAddress ?? receiverId;
        final groupService = GroupService(userId: localId, keyManager: keyManager);
        try {
          await groupService.handleIncomingControlMessage(
            type,
            data['message'] as String,
          );
        } catch (e) {
          print('PrysmServer: group control handling failed: $e');
          return Response.internalServerError(
            body: jsonEncode({'error': 'Group control processing failed'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        return Response.ok(
          jsonEncode({'status': 'received', 'id': data['id']}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // File validation (direct + group media)
      if (['file', 'image', 'audio', groupFileType, groupImageType, groupAudioType]
              .contains(type) &&
          !_hasValidFileMetadata(data)) {
        return _badRequest('File metadata required: fileName, fileSize');
      }

      if (isGroupMessageType(type) && data['groupId'] == null) {
        return _badRequest('groupId required for group messages');
      }

      final receiverId = data['receiverId'] as String;
      final senderId = data['senderId'] as String;

      if (localOnionAddress != null) {
        if (senderId == localOnionAddress) {
          return Response.ok(
            jsonEncode({'status': 'received', 'id': data['id']}),
            headers: {'Content-Type': 'application/json'},
          );
        }
        if (receiverId != localOnionAddress) {
          return Response.forbidden(
            jsonEncode({'error': 'Message not addressed to this node'}),
            headers: {'Content-Type': 'application/json'},
          );
        }
      }

      // Ensure sender exists
      await DBHelper.ensureUserExist(senderId);

      // Fetch/refresh profile in background (always, to keep data fresh)
      _fetchSenderProfile(senderId);

      final timeReceived = DateTime.now().millisecondsSinceEpoch;
      final incomingTimestamp = data['timestamp'];
      final messageTimestamp = incomingTimestamp is int && incomingTimestamp > 0
          ? incomingTimestamp
          : timeReceived;
      final localId = localOnionAddress ?? receiverId;
      await MessagesDb.insertInboundMessage({
        'id': data['id'] as String,
        'senderId': senderId,
        'receiverId': receiverId,
        'message': data['message'] as String,
        'type': type,
        if (data['groupId'] != null) 'groupId': data['groupId'] as String,
        if (data['fileName'] != null) 'fileName': data['fileName'] as String,
        if (data['fileSize'] != null) 'fileSize': data['fileSize'],
        'timestamp': messageTimestamp,
        'readAt': timeReceived,
        'status': (data['status'] ?? 'received') as String,
        if (data['replyTo'] != null) 'replyTo': data['replyTo'],
        'viewOnce': (data['viewOnce'] == true || data['viewOnce'] == 1) ? 1 : 0,
      }, localId);

      ConversationRefreshNotifier.instance.notifyInboundMessage();

      // Send local notification only if app is in background
      if (settings.enableNotifications) {
        final appState = WidgetsBinding.instance.lifecycleState;
        if (appState == AppLifecycleState.paused ||
            appState == AppLifecycleState.inactive ||
            appState == AppLifecycleState.detached) {
          final contact = await DBHelper.getUserById(
            data['senderId'] as String,
          );
          final senderName = contact?['name'] ?? 'Unknown contact';
          final body = isGroupMessageType(type)
              ? 'New group message from $senderName'
              : 'Open to view the message';
          NotificationService().showNewMessageNotification(
            senderName: isGroupMessageType(type) ? 'Group chat' : senderName,
            message: body,
            notificationId: Random().nextInt(99999999),
            payload: jsonEncode({
              'senderId': senderId,
              if (data['groupId'] != null) 'groupId': data['groupId'],
            }),
          );
        }
      }

      return Response.ok(
        jsonEncode({
          'status': 'received',
          'id': data['id'],
          'timestamp': timeReceived,
        }),
      );
    } catch (e, stack) {
      print('PrysmServer POST /message Error $e\n$stack');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Processing failed'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  Response _handleGetPublicKey() {
    return Response.ok(
      keyManager.publicKeyPem,
      headers: {'Content-Type': 'text/plain'},
    );
  }

  Response _handleGetProfile() {
    final broadcastName = settings.username;
    // Don't broadcast the default placeholder — only real user-set names
    final username = (broadcastName != null && broadcastName.isNotEmpty && broadcastName != 'My Profile')
        ? broadcastName
        : '';
    return Response.ok(
      jsonEncode({
        'publicKeyPem': keyManager.publicKeyPem,
        'username': username,
        'avatar': settings.avatar ?? '',
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  bool _isValidMessageData(dynamic data) {
    return data is Map &&
        data['id'] is String &&
        data['senderId'] is String &&
        data['receiverId'] is String &&
        data['message'] is String &&
        data['type'] is String &&
        data['timestamp'] is int;
  }

  bool _hasValidFileMetadata(dynamic data) {
    return data['fileName'] is String && data['fileSize'] is int;
  }

  void _fetchSenderProfile(String senderId) {
    if (!PeerProfileCache.instance.shouldFetch(senderId)) return;

    // Wrap in runZonedGuarded to prevent unhandled exceptions from
    // fire-and-forget async (Tor SOCKS errors like ttlExpired)
    Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (self, parent, zone, error, stackTrace) {
          print('Suppressed error in _fetchSenderProfile: $error');
        },
      ),
    ).run(() async {
      final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);
      try {
        final uri = Uri.parse('http://$senderId:80/profile');
        final response = await torClient.get(uri, {}).timeout(const Duration(seconds: 20));
        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;

        final updates = <String, dynamic>{};
        if (data['publicKeyPem'] != null && (data['publicKeyPem'] as String).isNotEmpty) {
          updates['publicKeyPem'] = data['publicKeyPem'];
        }
        if (data['username'] != null && (data['username'] as String).isNotEmpty) {
          updates['name'] = data['username'];
        }
        if (data['avatar'] != null && (data['avatar'] as String).isNotEmpty) {
          updates['avatarBase64'] = data['avatar'];
        }
        if (updates.isNotEmpty) {
          await DBHelper.updateUserFields(senderId, updates);
        }
        PeerProfileCache.instance.markFetched(senderId);
      } catch (e) {
        print('Failed to fetch sender profile: $e');
      } finally {
        torClient.close();
      }
    });
  }

  Response _badRequest(String message) {
    return Response(
      400,
      body: jsonEncode({'error': message}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}
