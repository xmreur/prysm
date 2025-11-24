import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/notification_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'message_db_helper.dart';

class MessageHttpServer {
  final int port;
  final KeyManager keyManager;

  MessageHttpServer({this.port = 8080, required this.keyManager});

  Future<void> start() async {
    Future<Response> handler(Request request) async {
      try {
        print("${request.method}|${request.url.path}");

        if (request.method == 'POST' && request.url.path == 'message') {
          return await _handlePostMessage(request);
        }

        if (request.method == 'GET' && request.url.path == 'public') {
          return _handleGetPublicKey();
        }

        if (request.method == 'GET' &&
            request.url.pathSegments.length == 2 &&
            request.url.pathSegments[0] == 'file') {
          return await _handleGetFile(request.url.pathSegments[1]);
        }

        return Response.notFound('Not found');
      } catch (e, stacktrace) {
        print('Error handling request: $e\n$stacktrace');
        return Response.internalServerError(
            body: jsonEncode({'error': 'Internal Server Error'}),
            headers: {'Content-Type': 'application/json'});
      }
    }

    await io.serve(handler, '0.0.0.0', port, shared: true);
    print('Message HTTP server running on port $port');
  }

  Future<Response> _handlePostMessage(Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload);

      print('Received message ${data['type']}');

      if (!_isValidMessageData(data)) {
        return _badRequest('Invalid message data');
      }

      if (['file', 'image'].contains(data['type']) &&
          !_hasValidFileMetadata(data)) {
        return _badRequest('Missing or invalid file metadata');
      }

      final int timeReceived = DateTime.now().millisecondsSinceEpoch;

      await DBHelper.ensureUserExist(data['senderId']);

      await MessageDbHelper.insertMessage({
        'id': data['id'],
        'senderId': data['senderId'],
        'receiverId': data['receiverId'],
        'message': data['message'],
        'type': data['type'],
        'fileName': data['fileName'],
        'fileSize': data['fileSize'],
        'timestamp': timeReceived,
        'status': data['status'] ?? 'received',
        'replyTo': data['replyTo'],
      });

      final contact = await DBHelper.getUserById(data['senderId']);
      NotificationService().showNewMessageNotification(
          senderName: contact?['name'] ?? 'Unknown',
          message: 'Open to view the message',
          notificationId: Random().nextInt(99999999));

      return Response.ok(
          jsonEncode({'status': 'received', 'id': data['id']}),
          headers: {'Content-Type': 'application/json'});
    } catch (e) {
      print('Error processing POST /message: $e');
      return Response.internalServerError(
          body: jsonEncode({'error': 'Server error'}),
          headers: {'Content-Type': 'application/json'});
    }
  }

  Response _handleGetPublicKey() {
    final publicPem = keyManager.publicKeyPem;
    return Response.ok(publicPem, headers: {'Content-Type': 'text/plain'});
  }

  Future<Response> _handleGetFile(String fileId) async {
    final messages = await MessageDbHelper.getMessageById(fileId);

    if (messages.isEmpty) {
      return Response.notFound("File not found");
    }

    final msg = messages.first;
    final fileName = msg['fileName'] ?? "unknown";
    final fileBytesBase64 = msg['message']; // base64 encrypted content

    try {
      final fileBytes = base64Decode(fileBytesBase64);
      return Response.ok(
        fileBytes,
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Disposition': 'attachment; filename="$fileName"',
        },
      );
    } catch (e) {
      return Response.internalServerError(
          body: 'Failed to decode file data');
    }
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
    return Response(400,
        body: jsonEncode({'error': message}),
        headers: {'Content-Type': 'application/json'});
  }
}
