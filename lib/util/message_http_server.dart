import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'message_db_helper.dart';

class MessageHttpServer {
  final int port;

  MessageHttpServer({this.port = 8080});

  Future<void> start() async {
    Future<Response> handler(Request request) async {
      if (request.method == 'POST' && request.url.path == 'message') {
        final payload = await request.readAsString();
        final data = jsonDecode(payload);

        // Example validation - adjust as needed
        if (data['id'] == null ||
            data['senderId'] == null ||
            data['receiverId'] == null ||
            data['message'] == null ||
            data['timestamp'] == null) {
          return Response(400,
              body: jsonEncode({'error': 'Invalid message data'}),
              headers: {'Content-Type': 'application/json'});
        }

        // Insert message into DB
        await MessageDbHelper.insertMessage(data);

        // Respond success
        return Response.ok(
            jsonEncode({'status': 'received', 'id': data['id']}),
            headers: {'Content-Type': 'application/json'});
      }
      return Response.notFound('Not found');
    }

    final server = await io.serve(handler, '0.0.0.0', port);
    print('Message HTTP server running on port ${server.port}');
  }
}
