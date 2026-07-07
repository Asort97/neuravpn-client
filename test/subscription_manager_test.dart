import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/subscription_manager.dart';

const _firstVless =
    'vless://d432a14b-3e92-4649-8095-781aaa039caa@example.com:443'
    '?encryption=none&security=reality&sni=example.com&fp=chrome'
    '&pbk=abc&sid=123&type=xhttp&path=%2F#one';
const _secondVless =
    'vless://d432a14b-3e92-4649-8095-781aaa039caa@example.com:8443'
    '?encryption=none&security=reality&sni=example.com&fp=chrome'
    '&pbk=abc&sid=123&type=tcp#two';

Future<Uri> _serveBody(String body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  server.listen((request) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write(body)
      ..close();
  });
  return Uri.parse('http://${server.address.host}:${server.port}/sub');
}

void main() {
  test('fetchSubscription accepts plain text VLESS subscriptions', () async {
    final uri = await _serveBody('$_firstVless $_secondVless');
    final service = SubscriptionService(timeout: const Duration(seconds: 3));

    final profiles = await service.fetchSubscription(uri.toString());

    expect(profiles, <String>[_firstVless, _secondVless]);
  });

  test('fetchSubscription accepts base64 VLESS subscriptions', () async {
    final encoded = base64.encode(utf8.encode('$_firstVless\n$_secondVless'));
    final uri = await _serveBody(encoded);
    final service = SubscriptionService(timeout: const Duration(seconds: 3));

    final profiles = await service.fetchSubscription(uri.toString());

    expect(profiles, <String>[_firstVless, _secondVless]);
  });
}
