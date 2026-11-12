import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:happycat_vpnclient/vless/xray_profile.dart';
import 'package:happycat_vpnclient/vless/xray_profile_config.dart';

import 'support/xray_subscription.dart';

/// Real loopback Xray transports. No TUN, DNS/route changes or live credentials.
/// Observatory alone reaches the public HTTPS 204 endpoint using the PC's
/// current network. Run explicitly with NEURA_RUNTIME_TESTS=1.
void main() {
  test(
    'HTTPS over TCP/XHTTP/HY2, leastPing failover and fail-closed',
    () async {
      final root = await Directory.systemTemp.createTemp('neura_auto_runtime_');
      final processes = <Process>[];
      final subscriptions = <StreamSubscription<String>>[];
      final logs = <String>[];
      final xray = File('assets/bin/xray.exe').absolute.path;
      const openssl = r'C:\Program Files\Git\usr\bin\openssl.exe';
      Future<void> stop(Process process) async {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
        processes.remove(process);
      }

      Future<int> freePort() async {
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = socket.port;
        await socket.close();
        return port;
      }

      Future<Process> start(String name, Map<String, dynamic> config) async {
        final file = File('${root.path}/$name.json');
        await file.writeAsString(jsonEncode(config));
        final process = await Process.start(xray, ['run', '-c', file.path]);
        processes.add(process);
        for (final stream in [process.stdout, process.stderr]) {
          subscriptions.add(
            stream
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .listen((line) => logs.add('$name: $line')),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
        return process;
      }

      HttpServer? target;
      try {
        final cert = '${root.path}/cert.pem';
        final key = '${root.path}/key.pem';
        final created = await Process.run(openssl, [
          'req',
          '-x509',
          '-newkey',
          'rsa:2048',
          '-nodes',
          '-days',
          '1',
          '-subj',
          '/CN=localhost',
          '-addext',
          'subjectAltName=DNS:localhost,IP:127.0.0.1',
          '-keyout',
          key,
          '-out',
          cert,
        ]);
        expect(created.exitCode, 0);
        final context = SecurityContext()
          ..useCertificateChain(cert)
          ..usePrivateKey(key);
        target = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          context,
        );
        var received = 0;
        target.listen((request) async {
          received++;
          request.response.write('neura-payload-$received');
          await request.response.close();
        });
        final der = await Process.run(openssl, [
          'x509',
          '-in',
          cert,
          '-outform',
          'DER',
        ], stdoutEncoding: null);
        expect(der.exitCode, 0);
        final pin = sha256.convert(der.stdout as List<int>).toString();
        final candidates = <Map<String, dynamic>>[];
        final servers = <Process>[];
        const uuid = '11111111-1111-4111-8111-111111111111';
        for (final transport in ['tcp', 'xhttp', 'hysteria']) {
          final port = await freePort();
          final hy = transport == 'hysteria';
          final stream = <String, dynamic>{
            'network': transport,
            'security': 'tls',
            'tlsSettings': {
              'alpn': hy ? ['h3'] : ['h2', 'http/1.1'],
              'certificates': [
                {'certificateFile': cert, 'keyFile': key},
              ],
            },
            if (transport == 'xhttp')
              'xhttpSettings': {'path': '/test', 'mode': 'auto'},
            if (hy) ...{
              'hysteriaSettings': {'version': 2},
              'finalmask': {
                'udp': [
                  {
                    'type': 'salamander',
                    'settings': {'password': 'test-obfs'},
                  },
                ],
              },
            },
          };
          servers.add(
            await start('server-$transport', {
              'log': {'loglevel': 'info'},
              'inbounds': [
                {
                  'listen': '127.0.0.1',
                  'port': port,
                  'protocol': hy ? 'hysteria' : 'vless',
                  'settings': hy
                      ? {
                          'version': 2,
                          'clients': [
                            {'auth': 'test-auth'},
                          ],
                        }
                      : {
                          'clients': [
                            {'id': uuid},
                          ],
                          'decryption': 'none',
                        },
                  'streamSettings': stream,
                },
              ],
              'outbounds': [
                {'protocol': 'freedom'},
              ],
            }),
          );
          final clientStream =
              jsonDecode(jsonEncode(stream)) as Map<String, dynamic>;
          clientStream['tlsSettings'] = {
            'serverName': 'localhost',
            'alpn': hy ? ['h3'] : ['h2', 'http/1.1'],
            'pinnedPeerCertSha256': pin,
          };
          if (hy) {
            clientStream['hysteriaSettings'] = {
              'version': 2,
              'auth': 'test-auth',
            };
          }
          candidates.add({
            'tag': 'auto-$transport',
            'protocol': hy ? 'hysteria' : 'vless',
            'settings': hy
                ? {'version': 2, 'address': '127.0.0.1', 'port': port}
                : {
                    'vnext': [
                      {
                        'address': '127.0.0.1',
                        'port': port,
                        'users': [
                          {'id': uuid, 'encryption': 'none'},
                        ],
                      },
                    ],
                  },
            'streamSettings': clientStream,
            'mux': {'enabled': false},
          });
        }
        Future<ProcessResult> request(int port) => Process.run('curl.exe', [
          '--disable',
          '--noproxy',
          '',
          '--proxy',
          'socks5h://127.0.0.1:$port',
          '--max-time',
          '4',
          '--silent',
          '--show-error',
          '--cacert',
          cert,
          'https://127.0.0.1:${target!.port}/payload',
        ]);
        for (final candidate in candidates) {
          final profile = xraySubscriptionProfile();
          profile.remove('observatory');
          profile['outbounds'] = [candidate];
          profile['routing'] = {
            'rules': [
              {
                'type': 'field',
                'network': 'tcp,udp',
                'outboundTag': candidate['tag'],
              },
            ],
          };
          final port = await freePort();
          final singleConfig = jsonDecode(
            adaptXrayProfile(XrayProfile.fromJson(profile), socksPort: port),
          );
          singleConfig['log'] = {'loglevel': 'info'};
          final process = await start(
            'client-${candidate['tag']}',
            singleConfig,
          );
          final response = await request(port);
          expect(
            response.exitCode,
            0,
            reason:
                '${candidate['tag']}: ${response.stderr}\n${logs.join('\n')}',
          );
          expect(response.stdout.toString(), startsWith('neura-payload-'));
          await stop(process);
        }
        final source = xraySubscriptionProfile();
        source['outbounds'] = [
          ...candidates,
          {'tag': 'unavailable', 'protocol': 'blackhole'},
        ];
        source['observatory']['probeUrl'] =
            'https://www.gstatic.com/generate_204';
        final port = await freePort();
        final config = jsonDecode(
          adaptXrayProfile(XrayProfile.fromJson(source), socksPort: port),
        );
        config['log'] = {'loglevel': 'info'};
        final client = await start('auto-client', config);
        Future<void> waitForTraffic() async {
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          while (DateTime.now().isBefore(deadline)) {
            final response = await request(port);
            if (response.exitCode == 0 &&
                response.stdout.toString().startsWith('neura-payload-')) {
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
          fail('No automatic route carried HTTPS: ${logs.join('\n')}');
        }

        await waitForTraffic();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        String selected() => logs.reversed
            .map(
              (line) => RegExp(
                r'\[socks (?:->|>>) (auto-(?:tcp|xhttp|hysteria))\]',
              ).firstMatch(line)?.group(1),
            )
            .whereType<String>()
            .first;
        final before = selected();
        final selectedIndex = candidates.indexWhere(
          (out) => out['tag'] == before,
        );
        expect(selectedIndex, greaterThanOrEqualTo(0));
        await stop(servers[selectedIndex]);
        logs.clear();
        await waitForTraffic();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(selected(), isNot(before));
        // Model a network where only the UDP-based Hysteria2 transport works.
        for (var i = 0; i < 2; i++) {
          if (processes.contains(servers[i])) await stop(servers[i]);
        }
        if (!processes.contains(servers.last)) {
          servers[2] = await start(
            'server-hysteria-return',
            jsonDecode(
                  await File(
                    '${root.path}/server-hysteria.json',
                  ).readAsString(),
                )
                as Map<String, dynamic>,
          );
        }
        logs.clear();
        await waitForTraffic();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(selected(), 'auto-hysteria');
        for (final server in servers) {
          if (processes.contains(server)) await stop(server);
        }
        final count = received;
        final blocked = await request(port);
        expect(blocked.exitCode, isNot(0));
        expect(
          received,
          count,
          reason: 'All-dead must never fall back to direct',
        );
        await stop(client);
      } finally {
        for (final process in processes.toList()) {
          await stop(process);
        }
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        await target?.close(force: true);
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip:
        !Platform.isWindows ||
        Platform.environment['NEURA_RUNTIME_TESTS'] != '1',
  );
}
