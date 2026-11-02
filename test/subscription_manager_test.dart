import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/subscription_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/subscription_identity.dart';

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
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'neura_subscription_test_',
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  SubscriptionService serviceFor(
    http.Client client, {
    bool windows = false,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
  }) {
    addTearDown(client.close);
    return SubscriptionService(
      client: client,
      identity: testSubscriptionIdentity(directory),
      timeout: const Duration(seconds: 3),
      isWindowsOverride: windows,
      runProcess: runProcess,
    );
  }

  test('fetchSubscription accepts plain text VLESS subscriptions', () async {
    final uri = await _serveBody('$_firstVless $_secondVless');
    final service = serviceFor(http.Client());

    final profiles = await service.fetchSubscription(uri.toString());

    expect(profiles, <String>[_firstVless, _secondVless]);
  });

  test('fetchSubscription accepts base64 VLESS subscriptions', () async {
    final encoded = base64.encode(utf8.encode('$_firstVless\n$_secondVless'));
    final uri = await _serveBody(encoded);
    final service = serviceFor(http.Client());

    final profiles = await service.fetchSubscription(uri.toString());

    expect(profiles, <String>[_firstVless, _secondVless]);
  });

  test(
    'every import, refresh and redirect sends the same installation headers',
    () async {
      final requests = <Map<String, String>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add({
          for (final name in [
            'x-hwid',
            'x-device-os',
            'x-device-model',
            'user-agent',
          ])
            name: request.headers.value(name) ?? '',
        });
        if (request.uri.path == '/redirect') {
          request.response.statusCode = 302;
          request.response.headers.set('location', '/sub');
        } else {
          request.response.write(_firstVless);
        }
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/redirect';
      final service = serviceFor(http.Client());
      await service.fetchSubscription(url);
      await service.fetchSubscription(url);
      await serviceFor(http.Client()).fetchSubscription(url);
      expect(requests, hasLength(6));
      expect(requests.map((h) => h['x-hwid']).toSet(), hasLength(1));
      for (final headers in requests) {
        expect(headers['x-hwid'], isNotEmpty);
        expect(headers['x-device-os'], 'Windows');
        expect(headers['x-device-model'], 'Test PC');
        expect(headers['user-agent'], 'NeuraVPN/1.0.14 (Windows; build 14)');
      }
    },
  );

  test('redirects are bounded and unsupported schemes are rejected', () async {
    var requests = 0;
    final loop = serviceFor(
      MockClient((_) async {
        requests++;
        return http.Response('', 302, headers: {'location': '/loop'});
      }),
    );
    await expectLater(
      loop.fetchSubscription('https://example.com/sub'),
      throwsA(isA<SubscriptionFetchException>()),
    );
    expect(requests, 6);
    final invalid = serviceFor(
      MockClient(
        (_) async => http.Response(
          '',
          307,
          headers: {'location': 'file:///private.txt'},
        ),
      ),
    );
    await expectLater(
      invalid.fetchSubscription('https://example.com/sub'),
      throwsA(isA<SubscriptionFetchException>()),
    );
  });

  test(
    'real Windows curl forwards all headers across redirect and preserves limit',
    () async {
      final requests = <Map<String, String>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add({
          for (final name in [
            'x-hwid',
            'x-device-os',
            'x-device-model',
            'user-agent',
          ])
            name: request.headers.value(name) ?? '',
        });
        if (request.uri.path == '/redirect') {
          request.response.statusCode = 307;
          request.response.headers.set('location', '/limited');
        } else {
          request.response.statusCode = 429;
          request.response.headers.set('X-Neura-Device-Limit', 'true');
          request.response.headers.set(
            'Profile-Title',
            'base64:${base64.encode(utf8.encode('Limit reached'))}',
          );
          request.response.write(_firstVless);
        }
        await request.response.close();
      });
      final service = serviceFor(
        MockClient((_) async => throw const HandshakeException('force curl')),
        windows: true,
      );
      await expectLater(
        service.fetchSubscription('http://127.0.0.1:${server.port}/redirect'),
        throwsA(
          isA<SubscriptionDeviceLimitException>().having(
            (e) => e.message,
            'decoded title',
            'Limit reached',
          ),
        ),
      );
      expect(requests, hasLength(2));
      expect(requests[0], requests[1]);
      expect(requests[0]['x-hwid'], isNotEmpty);
      expect(requests[0]['x-device-os'], 'Windows');
      expect(requests[0]['x-device-model'], 'Test PC');
      expect(requests[0]['user-agent'], 'NeuraVPN/1.0.14 (Windows; build 14)');
    },
    skip: !Platform.isWindows,
  );

  for (final status in [200, 403, 429]) {
    test(
      'device limit HTTP $status shows decoded title and rejects valid dummy',
      () async {
        const title =
            '\u041b\u0438\u043c\u0438\u0442 \u0443\u0441\u0442\u0440\u043e\u0439\u0441\u0442\u0432: 3';
        final service = serviceFor(
          MockClient(
            (_) async => http.Response(
              _firstVless,
              status,
              headers: {
                'X-Neura-Device-Limit': ' TRUE ',
                'Profile-Title': 'base64:${base64.encode(utf8.encode(title))}',
              },
            ),
          ),
        );
        await expectLater(
          service.fetchSubscription('https://example.com/sub'),
          throwsA(
            isA<SubscriptionDeviceLimitException>().having(
              (e) => e.message,
              'decoded title',
              title,
            ),
          ),
        );
      },
    );
  }

  for (final title in [null, '', 'base64:!!!', 'base64:/w==', 'base64:IA==']) {
    test(
      'missing or invalid title $title still produces a device-limit error',
      () async {
        final service = serviceFor(
          MockClient(
            (_) async => http.Response(
              'not a profile',
              200,
              headers: {
                'x-neura-device-limit': 'true',
                if (title != null) 'profile-title': title,
              },
            ),
          ),
        );
        await expectLater(
          service.fetchSubscription('https://example.com/sub'),
          throwsA(
            isA<SubscriptionDeviceLimitException>().having(
              (e) => e.message,
              'fallback',
              contains(
                '\u043b\u0438\u043c\u0438\u0442 \u0443\u0441\u0442\u0440\u043e\u0439\u0441\u0442\u0432',
              ),
            ),
          ),
        );
      },
    );
  }

  test('plain and unpadded base64url titles are supported', () async {
    const title = 'Device limit reached';
    for (final header in [
      title,
      'base64:${base64Url.encode(utf8.encode(title)).replaceAll('=', '')}',
    ]) {
      final service = serviceFor(
        MockClient(
          (_) async => http.Response(
            '',
            200,
            headers: {'x-neura-device-limit': 'true', 'profile-title': header},
          ),
        ),
      );
      await expectLater(
        service.fetchSubscription('https://example.com/sub'),
        throwsA(
          isA<SubscriptionDeviceLimitException>().having(
            (e) => e.message,
            'title',
            title,
          ),
        ),
      );
    }
  });

  test(
    'false device-limit flag does not block normal VLESS and HY2 subscriptions',
    () async {
      const body =
          '$_firstVless\nhysteria2://secret@example.com:443#HY2\nhy2://secret@example.net:8443';
      for (final encoded in [true, false]) {
        final service = serviceFor(
          MockClient(
            (_) async => http.Response(
              encoded ? base64.encode(utf8.encode(body)) : body,
              200,
              headers: {
                'x-neura-device-limit': 'false',
                'profile-title': 'base64:!!!',
              },
            ),
          ),
        );
        expect(
          await service.fetchSubscription('https://example.com/sub'),
          body.split('\n'),
        );
      }
    },
  );

  test(
    'curl keeps request identity and reads limit from final HTTP response',
    () async {
      late http.Request firstRequest;
      late String dumpPath;
      final service = serviceFor(
        MockClient((request) async {
          firstRequest = request;
          throw const HandshakeException('test');
        }),
        windows: true,
        runProcess: (executable, args) async {
          expect(executable, 'curl.exe');
          expect(args.first, '--disable');
          expect(args, isNot(contains('--insecure')));
          for (final name in [
            'X-HWID',
            'X-Device-OS',
            'X-Device-Model',
            'User-Agent',
          ]) {
            expect(args, contains('$name: ${firstRequest.headers[name]}'));
          }
          dumpPath = args[args.indexOf('--dump-header') + 1];
          await File(dumpPath).writeAsString(
            'HTTP/1.1 200 Connection established\r\n\r\n'
            'HTTP/1.1 302 Found\r\nLocation: /final\r\n\r\n'
            'HTTP/2 403\r\nX-Neura-Device-Limit: true\r\n'
            'Profile-Title: base64:${base64.encode(utf8.encode('Device quota exceeded'))}\r\n\r\n',
          );
          return ProcessResult(1, 0, utf8.encode(_firstVless), '');
        },
      );
      await expectLater(
        service.fetchSubscription('https://example.com/sub'),
        throwsA(
          isA<SubscriptionDeviceLimitException>().having(
            (e) => e.message,
            'title',
            'Device quota exceeded',
          ),
        ),
      );
      expect(await File(dumpPath).parent.exists(), isFalse);
    },
  );

  test(
    'curl ignores proxy and redirect headers when final response is normal',
    () async {
      final service = serviceFor(
        MockClient((_) async => throw const SocketException('test')),
        windows: true,
        runProcess: (_, args) async {
          await File(args[args.indexOf('--dump-header') + 1]).writeAsString(
            'HTTP/1.1 302 Found\r\nX-Neura-Device-Limit: true\r\n\r\n'
            'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n',
          );
          return ProcessResult(1, 0, utf8.encode(_secondVless), '');
        },
      );
      expect(await service.fetchSubscription('https://example.com/sub'), [
        _secondVless,
      ]);
    },
  );

  test(
    'cannot send a request if installation ID could not be persisted',
    () async {
      final blocked = File('${directory.path}/blocked');
      await blocked.writeAsString('blocked');
      var requests = 0;
      final service = SubscriptionService(
        identity: testSubscriptionIdentity(Directory(blocked.path)),
        client: MockClient((_) async {
          requests++;
          return http.Response(_firstVless, 200);
        }),
      );
      await expectLater(
        service.fetchSubscription('https://example.com/sub'),
        throwsA(isA<SubscriptionFetchException>()),
      );
      expect(requests, 0);
    },
  );
}
