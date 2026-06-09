import 'dart:convert';
import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

class TorHttpClient {
  String proxyHost;
  final int proxyPort;
  late HttpClient _httpClient;

  TorHttpClient({this.proxyHost = '127.0.0.1', this.proxyPort = 9050}) {
    _httpClient = HttpClient();

    SocksTCPClient.assignToHttpClient(
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
    headers.forEach((key, value) {
      request.headers.set(key, value);
    });
    request.write(body);
    return request.close();
  }

  Future<HttpClientResponse> get(Uri uri, Map<String, String> headers) async {
    final request = await _httpClient.getUrl(uri);
    headers.forEach((key, value) {
      request.headers.set(key, value);
    });
    return request.close();
  }

  /// Reads the full UTF-8 body and drains the socket before [close].
  Future<String> readUtf8Body(HttpClientResponse response) async {
    try {
      return await response.transform(utf8.decoder).join();
    } finally {
      try {
        await response.drain();
      } catch (_) {}
    }
  }

  void close() {
    // Do not use force: true — it tears down active response streams and
    // causes unhandled HttpException errors on Tor/SOCKS connections.
    _httpClient.close();
  }
}
