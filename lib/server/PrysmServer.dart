import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import '../database/messages.dart';
import 'package:prysm/services/settings_service.dart';

class PrysmServer {
  final int port;
  final KeyManager keyManager;
  HttpServer? _server;

  final settings = SettingsService();

  PrysmServer({this.port = 8080, required this.keyManager});

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

      // GET /public (public key)
      if (request.method == 'GET' && request.url.path == 'public') {
        return _handleGetPublicKey();
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

      if (!_isValidMessageData(data)) {
        return _badRequest(
          'Missing required fields: id, senderId, receiverId, message, type, timestamp',
        );
      }

      // File validation
      if (['file', 'image'].contains(data['type']) &&
          !_hasValidFileMetadata(data)) {
        return _badRequest('File metadata required: fileName, fileSize');
      }

      // Ensure sender exists
      await DBHelper.ensureUserExist(data['senderId'] as String);

      final timeReceived = DateTime.now().millisecondsSinceEpoch;
      await MessagesDb.insertMessage({
        'id': data['id'] as String,
        'senderId': data['senderId'] as String,
        'receiverId': data['receiverId'] as String,
        'message': data['message'] as String,
        'type': data['type'] as String,
        if (data['fileName'] != null) 'fileName': data['fileName'] as String,
        if (data['fileSize'] != null) 'fileSize': data['fileSize'],
        'timestamp': timeReceived,
        'readAt': timeReceived,
        'status': (data['status'] ?? 'received') as String,
        if (data['replyTo'] != null) 'replyTo': data['replyTo'],
      });

      // Send local notification only if app is in background
      if (settings.enableNotifications) {
        final appState = WidgetsBinding.instance.lifecycleState;
        if (appState == AppLifecycleState.paused ||
            appState == AppLifecycleState.inactive ||
            appState == AppLifecycleState.detached) {
          final contact = await DBHelper.getUserById(
            data['senderId'] as String,
          );
          NotificationService().showNewMessageNotification(
            senderName: contact?['name'] ?? 'Unknown contact',
            message: 'Open to view the message',
            notificationId: Random().nextInt(99999999),
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

  Response _badRequest(String message) {
    return Response(
      400,
      body: jsonEncode({'error': message}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}
