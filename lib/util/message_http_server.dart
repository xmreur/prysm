import 'dart:convert';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'message_db_helper.dart';
import 'package:prysm/util/notification_service.dart';

class MessageHttpServer {
  final int port;
  final KeyManager keyManager;
  MessageHttpServer({this.port = 8080, required this.keyManager});

  Future<void> start() async {
    Future<Response> handler(Request request) async {
      //print("${request.url.path}");

      if (request.method == 'POST' && request.url.path == 'message') {
        final payload = await request.readAsString();
        final data = jsonDecode(payload);

        // Basic validation
        if (data['id'] == null ||
            data['senderId'] == null ||
            data['receiverId'] == null ||
            data['message'] == null ||
            data['type'] == null ||
            data['timestamp'] == null) {
          return Response(400,
              body: jsonEncode({'error': 'Invalid message data'}),
              headers: {'Content-Type': 'application/json'});
        }

        // Additional validation for files/images
        if (data['type'] == "file" || data['type'] == "image") {
          if (data['fileName'] == null || data['fileSize'] == null) {
            return Response(400,
                body: jsonEncode({'error': 'Missing file metadata'}),
                headers: {'Content-Type': 'application/json'});
          }
        }

        final int timeReceived = DateTime.now().millisecondsSinceEpoch;

        await DBHelper.ensureUserExist(data['senderId']);
        
        // Store message
        await MessageDbHelper.insertMessage({
          'id': data['id'],
          'senderId': data['senderId'],
          'receiverId': data['receiverId'],
          'message': data['message'],
          'type': data['type'],
          'fileName': data['fileName'], // may be null for text
          'fileSize': data['fileSize'], // may be null for text
          'timestamp': timeReceived, // Use server time, fixes message order bugging on device
          'status': data['status'] ?? 'received',
        });

        return Response.ok(
            jsonEncode({'status': 'received', 'id': data['id']}),
            headers: {'Content-Type': 'application/json'});
      }

      // Public key endpoint
      if (request.method == "GET" && request.url.path == "public") {
        final publicPem = keyManager.publicKeyPem;
        return Response.ok(publicPem, headers: {'Content-Type': 'text/plain'});
      }

      if (request.method == "GET" && request.url.pathSegments.length == 2 && request.url.pathSegments[0] == "file") {
        final fileId = request.url.pathSegments[1];
        final messages = await MessageDbHelper.getMessageById(fileId);

        if (messages.isEmpty) {
          return Response.notFound("File not found");
        }

        final msg = messages.first;
        final fileName = msg['fileName'] ?? "unknown";
        final fileBytes = msg['message']; // base64 encrypted

        return Response.ok(
          base64Decode(fileBytes),
          headers: {
            'Content-Type': 'application/octet-stream',
            'Content-Disposition': 'attachment; filename="$fileName"',
          },
        );
      }


      return Response.notFound('Not found');
    }

    


    final server = await io.serve(handler, '0.0.0.0', port);
    //print('Message HTTP server running on port ${server.port}');
  }
}
