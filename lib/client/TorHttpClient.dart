import 'dart:io';
import 'package:socks5_proxy/socks_client.dart';

class TorHttpClient {
    String proxyHost;
    final int proxyPort;
    late HttpClient _httpClient;

    TorHttpClient({ this.proxyHost = '127.0.0.1', this.proxyPort = 9050}) {
        _httpClient = HttpClient();

        SocksTCPClient.assignToHttpClient(
            _httpClient,
            [
                ProxySettings(
                    InternetAddress(proxyHost),
                    proxyPort
                )
            ]
        );
    }

    Future<HttpClientResponse> post(Uri uri, Map<String, String> headers, String body) async {
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

    void close() {
        _httpClient.close(force: true);
    }
}