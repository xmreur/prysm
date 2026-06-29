import 'dart:convert';
import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

/// Binds [httpClient] to Tor SOCKS without the unsafe [SocksTCPClient.assignToHttpClient]
/// cancel path, which can throw when a socket is already attached to a stream.
void assignTorSocksToHttpClient(
  HttpClient httpClient,
  List<ProxySettings> proxies,
) {
  httpClient.connectionFactory = (uri, proxyHost, proxyPort) async {
    final Future<Socket> client = SocksTCPClient.connect(
      proxies,
      InternetAddress(uri.host, type: InternetAddressType.unix),
      uri.port,
    ).then<Socket>((socket) => socket);

    Future<void> tearDownSocket(Socket socket) async {
      try {
        socket.destroy();
      } catch (_) {
        try {
          await socket.close();
        } catch (_) {}
      }
    }

    return ConnectionTask.fromSocket(
      client,
      () async {
        try {
          await tearDownSocket(await client);
        } catch (_) {}
      },
    );
  };
}

class TorHttpClient {
  String proxyHost;
  final int proxyPort;
  late HttpClient _httpClient;
  bool _closed = false;

  TorHttpClient({this.proxyHost = '127.0.0.1', this.proxyPort = 9050}) {
    _httpClient = HttpClient();

    assignTorSocksToHttpClient(
      _httpClient,
      [
        ProxySettings(
          InternetAddress(proxyHost),
          proxyPort,
        ),
      ],
    );
  }

  Future<HttpClientResponse> post(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    final request = await _httpClient.postUrl(uri);
    final bodyBytes = utf8.encode(body);
    headers.forEach((key, value) {
      request.headers.set(key, value);
    });
    // Explicit length avoids chunked encoding, which can truncate or corrupt
    // large JSON bodies (e.g. file messages) through Tor/SOCKS.
    request.contentLength = bodyBytes.length;
    request.add(bodyBytes);
    return request.close();
  }

  Future<HttpClientResponse> get(Uri uri, Map<String, String> headers) async {
    final request = await _httpClient.getUrl(uri);
    headers.forEach((key, value) {
      request.headers.set(key, value);
    });
    return request.close();
  }

  /// Reads the full UTF-8 body. Call [close] after the body is consumed.
  Future<String> readUtf8Body(HttpClientResponse response) async {
    return response.transform(utf8.decoder).join();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Let the response stream finish detaching from the SOCKS socket before
    // HttpClient cancels the connection task.
    await Future<void>.value();
    try {
      _httpClient.close(force: false);
    } catch (_) {
      // socks5_proxy may throw when canceling a socket still bound to a stream
    }
  }
}
