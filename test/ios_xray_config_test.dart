import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/split_tunnel_config.dart';
import 'package:happycat_vpnclient/vless/config_generator.dart';
import 'package:happycat_vpnclient/vless/proxy_parser.dart';

void main() {
  final link = parseProxyUri(
    'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=tcp&sni=example.com',
  )!;

  test('iOS preserves Android routing and DNS with bounded buffers', () {
    final split = SplitTunnelConfig(
      mode: 'blacklist',
      domains: ['example.org', '10.0.0.0/8'],
    );
    final android = jsonDecode(generateAndroidXrayConfig(link, split)) as Map;
    final ios = jsonDecode(generateIOSXrayConfig(link, split)) as Map;
    expect(ios['routing'], android['routing']);
    expect(ios['dns'], android['dns']);
    expect(ios['inbounds'], android['inbounds']);
    expect(ios['outbounds'], android['outbounds']);
    expect(ios.remove('policy'), {
      'levels': {
        '0': {'bufferSize': 16},
      },
    });
    expect(ios.remove('env'), {'xray.buffer.size': '16'});
    expect(ios, android);
    expect(android.containsKey('policy'), isFalse);
    expect(android.containsKey('env'), isFalse);
  });

  test(
    'iOS ignores application packages and retains explicit smart domains',
    () {
      final config = generateIOSXrayConfig(
        link,
        SplitTunnelConfig(
          mode: 'blacklist',
          applications: ['com.secret.application'],
        ),
        smartRouting: true,
        smartDomains: ['example.ru'],
      );
      expect(config, isNot(contains('com.secret.application')));
      expect(config, contains('example.ru'));
      expect(config, isNot(contains('geosite:')));
      expect(config, isNot(contains('geoip:')));
    },
  );

  test('iOS rejects external geo files instead of silently ignoring rules', () {
    for (final prefix in ['geoip:', 'geosite:', 'ext:', 'ext-ip:']) {
      expect(
        () => generateIOSXrayConfig(
          link,
          SplitTunnelConfig(),
          extraRouteRules: [
            {
              'ip_cidr': ['${prefix}ru'],
              'outbound': 'direct',
            },
          ],
        ),
        throwsUnsupportedError,
      );
    }
  });
}
