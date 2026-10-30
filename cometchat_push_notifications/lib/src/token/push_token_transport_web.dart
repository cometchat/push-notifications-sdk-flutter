import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web: the browser's `fetch`, through `package:web`, which this package
/// already depends on.
Future<(int, String)> sendRequest(
  String method,
  Uri url,
  Map<String, String> headers,
  String? body,
) async {
  final requestHeaders = web.Headers();
  // A closure, not a tear-off: dart2js rejects tear-offs of interop members.
  headers.forEach((name, value) => requestHeaders.append(name, value));
  final response = await web.window
      .fetch(
        url.toString().toJS,
        web.RequestInit(
          method: method,
          headers: requestHeaders,
          body: body?.toJS,
        ),
      )
      .toDart
      .timeout(const Duration(seconds: 15));
  final text = (await response.text().toDart).toDart;
  return (response.status, text);
}
