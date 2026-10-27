import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/split_tunnel_config.dart';
import 'package:happycat_vpnclient/services/qr_import.dart';
import 'package:happycat_vpnclient/services/subscription_manager.dart';
import 'package:happycat_vpnclient/vless/config_generator.dart';
import 'package:happycat_vpnclient/vless/proxy_parser.dart';

const hy2 =
    'hysteria2://user%3Ap%40ss%2Bword@example.com/?sni=cdn.example.com#My%20server';
const vless =
    'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=tcp#VLESS';

void main() {
  test('HY2 auth, default port, SNI and name survive import', () {
    final link = parseProxyUri(hy2) as Hysteria2Link;
    expect(link.host, 'example.com');
    expect(link.port, 443);
    expect(link.auth, 'user:p@ss+word');
    expect(link.sni, 'cdn.example.com');
    expect(link.tag, 'My server');
    expect(link.isTls, isTrue);
    expect(parseQrImport(hy2), hy2);
    expect(parseProxyUri(vless), isA<VlessLink>());
  });

  test('short alias, IPv6, no auth and hopping ports', () {
    final link =
        parseProxyUri('hy2://[2001:db8::1]:443,5000-5010/?sni=example.com')
            as Hysteria2Link;
    expect(link.host, '2001:db8::1');
    expect(link.auth, '');
    expect(link.hoppingPorts, '443,5000-5010');
    final outbound = buildXrayProxyOutbound(link);
    expect(
      outbound['streamSettings']['finalmask']['quicParams']['udpHop']['ports'],
      '443,5000-5010',
    );
    expect(parseQrImport('hy2://pass@example.com:443,8443'), isNotNull);
  });

  test(
    'TLS pin and Salamander are retained without disabling certificate verification',
    () {
      final pin = List.filled(32, 'ab').join(':');
      final link = parseProxyUri(
        'hy2://pass@example.com:443?insecure=1&pinSHA256=$pin&obfs=salamander&obfs-password=a%26b',
      )!;
      expect(proxyValidationError(link), isNull);
      final outbound = buildXrayProxyOutbound(
        link,
        serverAddressOverride: '192.0.2.1',
      );
      expect(outbound['settings']['address'], '192.0.2.1');
      final stream = outbound['streamSettings'];
      expect(stream['tlsSettings']['serverName'], 'example.com');
      expect(stream['tlsSettings']['pinnedPeerCertSha256'], pin);
      expect(stream['tlsSettings'].containsKey('allowInsecure'), isFalse);
      expect(stream['finalmask']['udp'][0]['settings']['password'], 'a&b');
    },
  );

  test(
    'malformed or unsupported links never silently become another protocol',
    () {
      for (final value in [
        'hysteria://example.com:443?auth=pass',
        'hy2://',
        'hy2://pass@example.com:0',
        'hy2://pass@example.com:65536',
        'hy2://pass@example.com:443-1',
        'hy2://pass@example.com:443,',
        'hy2://pass@example.com:abc',
        'hy2://pass@example.com/path',
        'hy2://pass@example.com?pinSHA256=abc',
        'hy2://pass@example.com?insecure=yes',
        'hy2://pass@example.com?sni=a&sni=b',
        'hy2://%zz@example.com',
      ]) {
        expect(parseProxyUri(value), isNull, reason: value);
      }
      for (final query in [
        'insecure=1',
        'obfs=gecko',
        'obfs=salamander',
        'ech=abc',
      ]) {
        final raw = 'hy2://pass@example.com?$query';
        expect(proxyValidationError(parseProxyUri(raw)!), isNotNull);
        expect(parseQrImport(raw), isNull);
      }
    },
  );

  test(
    'both platforms keep DNS and smart routing with the same HY2 outbound',
    () {
      final link = parseProxyUri(hy2)!;
      final split = SplitTunnelConfig(mode: 'all');
      final android = jsonDecode(
        generateAndroidXrayConfig(
          link,
          split,
          smartRouting: true,
          smartDomains: ['example.ru'],
        ),
      );
      final windows = jsonDecode(generateWindowsXrayProxyConfig(link, split));
      for (final config in [android, windows]) {
        final outbound = config['outbounds'][0];
        expect(outbound['protocol'], 'hysteria');
        expect(outbound['settings']['version'], 2);
        expect(
          outbound['streamSettings']['hysteriaSettings']['auth'],
          'user:p@ss+word',
        );
        expect(config['dns']['disableCache'], isFalse);
        expect(
          (config['routing']['rules'] as List).any(
            (rule) =>
                (rule['inboundTag'] as List?)?.contains('dns-query') == true &&
                rule['outboundTag'] == 'My server',
          ),
          isTrue,
        );
      }
      expect(android['dns']['servers'][0]['address'], 'localhost');
      expect(
        android['dns']['servers'][1]['address'],
        'https://9.9.9.9/dns-query',
      );
    },
  );

  test(
    'plain and base64 subscriptions preserve mixed protocols and deduplicate',
    () async {
      for (final encoded in [false, true]) {
        final body = '$vless\n$hy2\nhy2://pass@example.net:8443\n$hy2';
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) {
          request.response.write(
            encoded ? base64.encode(utf8.encode(body)) : body,
          );
          request.response.close();
        });
        try {
          final result = await SubscriptionService().fetchSubscription(
            'http://127.0.0.1:${server.port}/sub',
          );
          expect(result, [vless, hy2, 'hy2://pass@example.net:8443']);
        } finally {
          await server.close(force: true);
        }
      }
      expect(SubscriptionService().isValidSubscriptionUrl(hy2), isFalse);
    },
  );

  test('bundled Xray accepts HY2, pin, obfuscation and port hopping', () async {
    if (!Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp(
      'neuravpn_hy2_test_',
    );
    try {
      final pin = 'ab' * 32;
      for (final uri in [
        hy2,
        'hy2://pass@example.com:443,8443?obfs=salamander&obfs-password=secret&pinSHA256=$pin',
      ]) {
        final link = parseProxyUri(uri)!;
        for (final config in [
          generateWindowsXrayProxyConfig(link, SplitTunnelConfig()),
          generateAndroidXrayConfig(link, SplitTunnelConfig()),
        ]) {
          final file = File('${directory.path}/config.json');
          await file.writeAsString(config);
          final result = await Process.run(
            File('assets/bin/xray.exe').absolute.path,
            ['run', '-test', '-c', file.path],
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        }
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
