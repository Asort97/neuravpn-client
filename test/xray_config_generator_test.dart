import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/split_tunnel_config.dart';
import 'package:happycat_vpnclient/vless/config_generator.dart';
import 'package:happycat_vpnclient/vless/vless_parser.dart';

const _uuid = '11111111-1111-1111-1111-111111111111';

VlessLink _parse(String uri) {
  final parsed = parseVlessUri(uri);
  expect(parsed, isNotNull);
  return parsed!;
}

void main() {
  test('generates xray config with api and stats sections', () {
    final link = _parse(
      'vless://$_uuid@example.com:443?security=tls&type=tcp&sni=example.com#proxy',
    );
    final config =
        jsonDecode(generateXrayConfig(link, SplitTunnelConfig(mode: 'all')))
            as Map<String, dynamic>;

    expect(config['api'], isNotNull);
    expect(config['stats'], isNotNull);
    expect((config['outbounds'] as List).isNotEmpty, isTrue);
    final dns = config['dns'] as Map<String, dynamic>;
    expect(dns['servers'], <String>['9.9.9.9', '149.112.112.112']);
    expect(jsonEncode(dns), isNot(contains('8.8.8.8')));
    expect(jsonEncode(dns), isNot(contains('1.1.1.1')));
  });

  test('adds anti-loop guard rule for link-local UDP broadcast traffic', () {
    final link = _parse(
      'vless://$_uuid@example.com:443?security=tls&type=tcp&sni=example.com#proxy',
    );
    final config =
        jsonDecode(generateXrayConfig(link, SplitTunnelConfig(mode: 'all')))
            as Map<String, dynamic>;
    final routing = config['routing'] as Map<String, dynamic>;
    final rules = (routing['rules'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

    final guardRule = rules.firstWhere(
      (rule) =>
          rule['network'] == 'udp' &&
          rule['outboundTag'] == 'block' &&
          (rule['ip'] as List<dynamic>? ?? const <dynamic>[])
              .map((e) => e.toString())
              .contains('169.254.0.0/16'),
      orElse: () => <String, dynamic>{},
    );
    expect(guardRule, isNotEmpty);
    expect(guardRule.containsKey('port'), isFalse);
  });

  test('maps reality settings into xray streamSettings', () {
    final link = _parse(
      'vless://$_uuid@example.com:443?security=reality&type=tcp&sni=reality.example&pbk=PUBKEY123&sid=abcd#proxy',
    );
    final config =
        jsonDecode(generateXrayConfig(link, SplitTunnelConfig(mode: 'all')))
            as Map<String, dynamic>;

    final outbounds = config['outbounds'] as List<dynamic>;
    final proxy = outbounds.cast<Map<String, dynamic>>().firstWhere(
      (item) => item['tag'] == 'proxy',
    );
    final stream = proxy['streamSettings'] as Map<String, dynamic>;
    expect(stream['security'], 'reality');
    expect(stream['realitySettings']['publicKey'], 'PUBKEY123');
  });

  test('maps xhttp transport into xray network settings', () {
    final link = _parse(
      'vless://$_uuid@example.com:443?security=tls&type=xhttp&sni=example.com&path=%2Fedge#proxy',
    );
    final config =
        jsonDecode(generateXrayConfig(link, SplitTunnelConfig(mode: 'all')))
            as Map<String, dynamic>;
    final outbounds = config['outbounds'] as List<dynamic>;
    final proxy = outbounds.cast<Map<String, dynamic>>().firstWhere(
      (item) => item['tag'] == 'proxy',
    );
    final stream = proxy['streamSettings'] as Map<String, dynamic>;
    expect(stream['network'], 'xhttp');
    expect(stream['xhttpSettings']['path'], '/edge');
  });

  test('preserves XHTTP mode and nested extra settings from subscriptions', () {
    final extra = Uri.encodeComponent(
      jsonEncode({
        'path': '/',
        'host': '',
        'mode': 'auto',
        'extra': {
          'xPaddingBytes': '100-1000',
          'scMaxBufferedPosts': 30,
          'noSSEHeader': false,
          'xmux': {'maxConcurrency': '16-32'},
        },
      }),
    );
    final link = _parse(
      'vless://$_uuid@example.com:443?security=reality&type=xhttp&sni=example.com&path=%2F&extra=$extra#proxy',
    );
    final config =
        jsonDecode(generateXrayConfig(link, SplitTunnelConfig(mode: 'all')))
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['tag'] == 'proxy');
    final settings =
        (proxy['streamSettings'] as Map<String, dynamic>)['xhttpSettings']
            as Map<String, dynamic>;

    expect(settings['host'], '');
    expect(settings['mode'], 'auto');
    expect(settings['xPaddingBytes'], '100-1000');
    expect(settings['scMaxBufferedPosts'], 30);
    expect(settings['noSSEHeader'], isFalse);
    expect(settings['xmux'], {'maxConcurrency': '16-32'});
    expect(validateVlessTransportForXray(link), isNull);
  });

  test('reports malformed XHTTP extra before Xray startup', () {
    final link = _parse(
      'vless://$_uuid@example.com:443?security=tls&type=xhttp&extra=%7Bbad#proxy',
    );
    expect(validateVlessTransportForXray(link), isNotNull);
  });

  test('binds outbound sockets to selected uplink interface', () {
    final link = _parse(
      'vless://$_uuid@example.com:443?security=tls&type=tcp&sni=example.com#proxy',
    );
    final config =
        jsonDecode(
              generateXrayConfig(
                link,
                SplitTunnelConfig(mode: 'all'),
                outboundInterfaceName: 'Ethernet',
                outboundBindAddress: '192.168.0.100',
              ),
            )
            as Map<String, dynamic>;
    final outbounds = (config['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final proxy = outbounds.firstWhere((item) => item['tag'] == 'proxy');
    final direct = outbounds.firstWhere((item) => item['tag'] == 'direct');

    expect(proxy['sendThrough'], '192.168.0.100');
    expect(direct['sendThrough'], '192.168.0.100');
    expect(
      ((proxy['streamSettings'] as Map<String, dynamic>)['sockopt']
          as Map<String, dynamic>)['interface'],
      'Ethernet',
    );
    expect(
      ((direct['streamSettings'] as Map<String, dynamic>)['sockopt']
          as Map<String, dynamic>)['interface'],
      'Ethernet',
    );
  });

  test('can pin xray server address while preserving tls host metadata', () {
    final link = _parse(
      'vless://$_uuid@example.com:443?security=tls&type=tcp&sni=example.com#proxy',
    );
    final config =
        jsonDecode(
              generateXrayConfig(
                link,
                SplitTunnelConfig(mode: 'all'),
                serverAddressOverride: '203.0.113.10',
                externalRouteManager: true,
              ),
            )
            as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['tag'] == 'proxy');
    final vnext =
        ((proxy['settings'] as Map<String, dynamic>)['vnext'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .single;
    final stream = proxy['streamSettings'] as Map<String, dynamic>;
    final inbound = (config['inbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['tag'] == 'tun-in');
    final tunSettings = inbound['settings'] as Map<String, dynamic>;

    expect(vnext['address'], '203.0.113.10');
    expect(stream['tlsSettings']['serverName'], 'example.com');
    expect(tunSettings['autoRoute'], isFalse);
    expect(tunSettings['strictRoute'], isFalse);
  });

  test('builds whitelist routing rule for domains and CIDR', () {
    final link = _parse(
      'vless://$_uuid@example.com:443?security=tls&type=tcp&sni=example.com#proxy',
    );
    final config =
        jsonDecode(
              generateXrayConfig(
                link,
                SplitTunnelConfig(
                  mode: 'whitelist',
                  domains: ['example.com', '1.1.1.1/32'],
                ),
              ),
            )
            as Map<String, dynamic>;

    final routing = config['routing'] as Map<String, dynamic>;
    final rules = (routing['rules'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final whitelistRule = rules.firstWhere(
      (rule) => rule['outboundTag'] == 'proxy',
      orElse: () => <String, dynamic>{},
    );

    expect(whitelistRule, isNotEmpty);
    expect(
      (whitelistRule['domain'] as List<dynamic>).contains('domain:example.com'),
      isTrue,
    );
    expect(
      (whitelistRule['ip'] as List<dynamic>).contains('1.1.1.1/32'),
      isTrue,
    );
    final outbounds = (config['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(outbounds.first['tag'], 'direct');
  });

  test('uses proxy as default outbound for blacklist mode', () {
    final link = _parse(
      'vless://$_uuid@example.com:443?security=tls&type=tcp&sni=example.com#proxy',
    );
    final config =
        jsonDecode(
              generateXrayConfig(
                link,
                SplitTunnelConfig(mode: 'blacklist', domains: ['example.com']),
              ),
            )
            as Map<String, dynamic>;
    final outbounds = (config['outbounds'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(outbounds.first['tag'], 'proxy');
  });

  test('maps split applications to xray process routing rule', () {
    final link = _parse(
      'vless://$_uuid@example.com:443?security=tls&type=tcp&sni=example.com#proxy',
    );
    final config =
        jsonDecode(
              generateXrayConfig(
                link,
                SplitTunnelConfig(
                  mode: 'whitelist',
                  applications: const ['C:\\Games\\Game\\game.exe'],
                ),
              ),
            )
            as Map<String, dynamic>;

    final routing = config['routing'] as Map<String, dynamic>;
    final rules = (routing['rules'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final processRule = rules.firstWhere(
      (rule) => rule['process'] != null,
      orElse: () => <String, dynamic>{},
    );
    expect(processRule, isNotEmpty);
    final processList = (processRule['process'] as List<dynamic>)
        .map((e) => e.toString())
        .toList();
    expect(processList.contains('C:\\Games\\Game\\game.exe'), isTrue);
    expect(processList.contains('game.exe'), isTrue);
  });
}
