import 'dart:convert';
import 'dart:io';

/// Android and iOS: `dart:io`, so registering a token adds no dependency.
Future<(int, String)> sendRequest(
  String method,
  Uri url,
  Map<String, String> headers,
  String? body,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.openUrl(method, url);
    headers.forEach(
      (name, value) =>
          request.headers.set(name, value, preserveHeaderCase: true),
    );
    if (body != null) request.add(utf8.encode(body));
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await response.transform(utf8.decoder).join();
    return (response.statusCode, text);
  } finally {
    client.close(force: true);
  }
}
