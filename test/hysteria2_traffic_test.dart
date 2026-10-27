import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/vless/config_generator.dart';
import 'package:happycat_vpnclient/vless/proxy_parser.dart';

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  for (final obfuscated in [false, true]) {
    test(
      'real HY2 transfers traffic over TLS/QUIC (Salamander=$obfuscated)',
      () async {
        if (!Platform.isWindows) return;
        final executable = File('assets/bin/xray.exe').absolute.path;
        final certResult = await Process.run(executable, [
          'tls',
          'cert',
          '--domain=localhost',
          '--expire=24h',
        ]);
        expect(certResult.exitCode, 0);
        final certificate = jsonDecode(certResult.stdout as String) as Map;
        final der = base64.decode(
          (certificate['certificate'] as List)
              .where((line) => !(line as String).startsWith('-----'))
              .join(),
        );
        final pin = sha256.convert(der).toString();
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        origin.listen((request) {
          request.response.write('neuravpn-hysteria2-traffic');
          request.response.close();
        });
        final udpSocket = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final remotePort = udpSocket.port;
        udpSocket.close();
        final proxyPort = await freePort();
        final link = parseProxyUri(
          'hy2://test-password@127.0.0.1:$remotePort?sni=localhost&pinSHA256=$pin${obfuscated ? '&obfs=salamander&obfs-password=mask-password' : ''}',
        )!;
        final outbound = buildXrayProxyOutbound(link);
        final stream = outbound['streamSettings'] as Map;
        final config = {
          'log': {'loglevel': 'warning'},
          'inbounds': [
            {
              'tag': 'local-client',
              'listen': '127.0.0.1',
              'port': proxyPort,
              'protocol': 'http',
              'settings': {},
            },
            {
              'tag': 'hy2-server',
              'listen': '127.0.0.1',
              'port': remotePort,
              'protocol': 'hysteria',
              'settings': {
                'version': 2,
                'clients': [
                  {'auth': 'test-password'},
                ],
              },
              'streamSettings': {
                'network': 'hysteria',
                'security': 'tls',
                'tlsSettings': {
                  'alpn': ['h3'],
                  'certificates': [certificate],
                },
                'hysteriaSettings': {'version': 2},
                if (obfuscated) 'finalmask': stream['finalmask'],
              },
            },
          ],
          'outbounds': [
            outbound,
            {'tag': 'direct', 'protocol': 'freedom'},
          ],
          'routing': {
            'rules': [
              {
                'type': 'field',
                'inboundTag': ['local-client'],
                'outboundTag': 'proxy',
              },
              {
                'type': 'field',
                'inboundTag': ['hy2-server'],
                'outboundTag': 'direct',
              },
            ],
          },
        };
        final directory = await Directory.systemTemp.createTemp(
          'neuravpn_hy2_traffic_',
        );
        Process? process;
        final logs = StringBuffer();
        final client = HttpClient()
          ..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
        client.connectionTimeout = const Duration(seconds: 3);
        try {
          final file = File('${directory.path}/config.json');
          await file.writeAsString(jsonEncode(config));
          process = await Process.start(executable, ['run', '-c', file.path]);
          process.stdout.transform(utf8.decoder).listen(logs.write);
          process.stderr.transform(utf8.decoder).listen(logs.write);
          var ready = false;
          for (var i = 0; i < 50; i++) {
            try {
              final socket = await Socket.connect(
                '127.0.0.1',
                proxyPort,
                timeout: const Duration(milliseconds: 100),
              );
              socket.destroy();
              ready = true;
              break;
            } on SocketException {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }
          expect(ready, isTrue, reason: logs.toString());
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/check'),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
          expect(response.statusCode, 200, reason: logs.toString());
          expect(
            await utf8.decoder
                .bind(response)
                .join()
                .timeout(const Duration(seconds: 5)),
            'neuravpn-hysteria2-traffic',
            reason: logs.toString(),
          );
        } finally {
          client.close(force: true);
          process?.kill();
          await process?.exitCode;
          await origin.close(force: true);
          await directory.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
