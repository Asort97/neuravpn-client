import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/split_tunnel_config.dart';
import 'package:happycat_vpnclient/models/vpn_profile.dart';
import 'package:happycat_vpnclient/models/vpn_subscription.dart';
import 'package:happycat_vpnclient/services/profile_availability.dart';
import 'package:happycat_vpnclient/services/subscription_manager.dart';
import 'package:happycat_vpnclient/services/subscription_repository.dart';
import 'package:happycat_vpnclient/vless/config_generator.dart';
import 'package:happycat_vpnclient/vless/proxy_parser.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/subscription_identity.dart';
import 'support/xray_subscription.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('neura_autoselect_');
  });
  tearDown(() => directory.delete(recursive: true));

  SubscriptionService service(http.Response response) => SubscriptionService(
    identity: testSubscriptionIdentity(directory),
    isWindowsOverride: false,
    client: MockClient((request) async {
      expect(request.headers['Accept'], 'application/vnd.neuravpn.xray+json');
      expect(request.headers['X-HWID'], isNotEmpty);
      expect(request.headers['X-Ver-OS'], isNotEmpty);
      expect(request.headers['User-Agent'], startsWith('NeuraVPN/'));
      return response;
    }),
  );

  test(
    'JSON and base64 JSON keep each complete profile and its remarks',
    () async {
      for (final encoded in [false, true]) {
        final first = xraySubscriptionProfile(candidates: 8);
        final second = xraySubscriptionProfile(
          candidates: 1,
          owner: '22222222-2222-4222-8222-222222222222',
        );
        final body = jsonEncode([first, second]);
        final profiles = await service(
          http.Response.bytes(
            utf8.encode(encoded ? base64Encode(utf8.encode(body)) : body),
            200,
            headers: {
              'content-type': 'application/json',
              'x-neura-autoselect': 'enabled',
            },
          ),
        ).fetchSubscription('https://example.com/account-a');
        expect(profiles, hasLength(2));
        expect(jsonDecode(profiles.first), first);
        expect(jsonDecode(profiles.last), second);
        final link = parseProxyUri(profiles.first) as XrayProfile;
        expect(link.tag, first['remarks']);
        expect(link.isAutomatic, isTrue);
        expect(isSecureProxyUri(profiles.first), isTrue);
        expect(
          VpnProfile.listFromJsonString(
            VpnProfile.listToJsonString([
              VpnProfile(name: link.tag, uri: profiles.first),
            ]),
          ).single.uri,
          profiles.first,
        );
      }
    },
  );

  test(
    'both runtimes preserve candidates, balancer, obfuscation, DNS and tags',
    () {
      final original = xraySubscriptionProfile();
      final link = XrayProfile.fromJson(original);
      for (final config in [
        jsonDecode(
          generateAndroidXrayConfig(
            link,
            SplitTunnelConfig(smartRouting: true),
          ),
        ),
        jsonDecode(
          generateWindowsXrayProxyConfig(
            link,
            SplitTunnelConfig(smartRouting: true),
          ),
        ),
      ]) {
        expect(config['dns'], original['dns']);
        expect(config['observatory'], original['observatory']);
        expect(
          config['routing']['balancers'],
          original['routing']['balancers'],
        );
        expect(
          config['routing']['rules'],
          containsAll(original['routing']['rules'] as List),
        );
        expect(
          (config['outbounds'] as List)
              .take((original['outbounds'] as List).length)
              .toList(),
          original['outbounds'],
        );
        expect(
          (config['outbounds'] as List).any((o) => o['protocol'] == 'freedom'),
          isFalse,
        );
        expect(
          (config['routing']['rules'] as List).last['outboundTag'],
          'unavailable',
        );
        for (final inbound in config['inbounds']) {
          expect(inbound['listen'], '127.0.0.1');
        }
        expect(
          (config['inbounds'] as List).map((i) => i['tag']),
          containsAll(['socks', 'http']),
        );
        expect(config['inbounds'][0]['port'], 10808);
      }
      expect(
        link.config,
        original,
        reason: 'adaptation must not mutate the saved profile',
      );
    },
  );

  test(
    'Windows binds every transport to physical uplink, never just first',
    () {
      final link = XrayProfile.fromJson(xraySubscriptionProfile(candidates: 7));
      final config = jsonDecode(
        generateWindowsXrayProxyConfig(
          link,
          SplitTunnelConfig(),
          outboundInterfaceName: 'Ethernet',
          outboundBindAddress: '192.168.0.2',
        ),
      );
      for (final out in config['outbounds']) {
        if (out['protocol'] == 'vless' || out['protocol'] == 'hysteria') {
          expect(out['sendThrough'], '192.168.0.2');
          expect(out['streamSettings']['sockopt']['interface'], 'Ethernet');
        }
      }
      final tun = jsonDecode(
        generateWindowsHybridTunConfig(
          SplitTunnelConfig(),
          inboundTag: 'tun',
          interfaceName: 'test',
          addresses: ['172.19.0.1/30'],
          useProfileDns: true,
        ),
      );
      expect(tun['dns']['servers'].single['server'], '172.19.0.2');
      expect(tun['dns']['servers'].single['detour'], 'proxy');
    },
  );

  test(
    'untrusted listeners are replaced; control APIs and unsafe fields rejected',
    () {
      final public = xraySubscriptionProfile();
      public['inbounds'][0]['listen'] = '0.0.0.0';
      public['inbounds'][0]['port'] = 80;
      final generated = jsonDecode(
        generateAndroidXrayConfig(
          XrayProfile.fromJson(public),
          SplitTunnelConfig(),
        ),
      );
      expect(generated['inbounds'][0]['listen'], '127.0.0.1');
      expect(generated['inbounds'][0]['port'], 10808);
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (c) => c['api'] = {'listen': '0.0.0.0:80'},
        (c) => c['reverse'] = {},
        (c) => c['routing']['script'] = 'unsafe',
        (c) => c['outbounds'][0]['streamSettings']['sockopt'] = {
          'dialerProxy': 'direct',
        },
        (c) => c['outbounds'][0]['streamSettings']['tlsSettings'] = {
          'certificateFile': 'secret',
        },
        (c) => c['routing']['balancers'][0]['fallbackTag'] = 'auto-hysteria2',
        (c) => c['routing']['balancers'][0]['selector'] = ['unavailable'],
        (c) => c['observatory']['probeUrl'] = 'http://example.com',
        (c) => c['outbounds'][0]['mux']['enabled'] = true,
      ]) {
        final input = xraySubscriptionProfile();
        mutate(input);
        expect(() => XrayProfile.fromJson(input), throwsFormatException);
      }
    },
  );

  test(
    'JSON is parsed atomically; a bad profile cannot drop only some nodes',
    () async {
      final invalid = xraySubscriptionProfile()..['api'] = {};
      await expectLater(
        service(
          http.Response.bytes(
            utf8.encode(jsonEncode([xraySubscriptionProfile(), invalid])),
            200,
          ),
        ).fetchSubscription('https://example.com/sub'),
        throwsA(isA<SubscriptionFetchException>()),
      );
    },
  );

  test('server-defined Go durations are preserved without client limits', () {
    for (final interval in [
      '10s',
      '60s',
      '1m',
      '1500ms',
      '1h',
      '1ms',
      '2h',
      '1m30s',
      '.5s',
      '+2s',
      '',
    ]) {
      final source = xraySubscriptionProfile();
      source['observatory']['probeInterval'] = interval;
      final profile = XrayProfile.fromJson(source);
      final config = jsonDecode(
        generateAndroidXrayConfig(profile, SplitTunnelConfig()),
      );
      expect(config['observatory']['probeInterval'], interval);
      final windows = jsonDecode(
        generateWindowsXrayProxyConfig(profile, SplitTunnelConfig()),
      );
      expect(windows['observatory']['probeInterval'], interval);
    }
    final defaults = xraySubscriptionProfile();
    defaults['observatory'].remove('probeInterval');
    expect(
      XrayProfile.fromJson(
        defaults,
      ).config['observatory'].containsKey('probeInterval'),
      isFalse,
    );
    for (final interval in ['0s', '-10s', 'invalid']) {
      final source = xraySubscriptionProfile();
      if (interval == null) {
        source['observatory'].remove('probeInterval');
      } else {
        source['observatory']['probeInterval'] = interval;
      }
      expect(() => XrayProfile.fromJson(source), throwsFormatException);
    }
  });

  test(
    'revocation, limit and legacy dummy are explicit denials, not profiles',
    () async {
      for (final headers in [
        {'X-Neura-Device-Revoked': 'true'},
        {'X-Neura-Device-Limit': 'true'},
      ]) {
        headers['Profile-Title'] =
            'base64:${base64Encode(utf8.encode('Device denied'))}';
        await expectLater(
          service(
            http.Response.bytes(
              utf8.encode(jsonEncode([xraySubscriptionProfile()])),
              200,
              headers: headers,
            ),
          ).fetchSubscription('https://example.com/sub'),
          throwsA(
            isA<SubscriptionDeviceLimitException>().having(
              (e) => e.message,
              'title',
              'Device denied',
            ),
          ),
        );
      }
      final placeholder =
          'vless://00000000-0000-4000-8000-000000000000@192.0.2.1:1?security=none#${Uri.encodeComponent('устройство было удалено')}';
      await expectLater(
        service(
          http.Response(base64Encode(utf8.encode(placeholder)), 200),
        ).fetchSubscription('https://example.com/sub'),
        throwsA(isA<SubscriptionDeviceRevokedException>()),
      );
    },
  );

  test(
    'denial clears only one subscription; restart retains no rejected keys',
    () async {
      final repo = SubscriptionRepository();
      final first = VpnSubscription(
        id: 'a',
        name: 'a',
        url: 'https://example.com/a',
        profiles: [jsonEncode(xraySubscriptionProfile())],
      );
      final other = VpnSubscription(
        id: 'b',
        name: 'b',
        url: 'https://example.com/b',
        profiles: ['other'],
      );
      // Concurrent additions must not lose one another.
      final a = repo.addSubscription(first);
      final b = SubscriptionRepository().addSubscription(other);
      expect(await a, isTrue);
      expect(await b, isTrue);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vpn_profile_selected_uri', first.profiles.single);
      final events = <Set<String>>[];
      final listener = SubscriptionRepository.revokedProfiles.listen(
        events.add,
      );
      addTearDown(listener.cancel);
      await repo.invalidateAccess(first.url, 'Device denied');
      final restored = await SubscriptionRepository().getAllSubscriptions();
      expect(restored.first.profiles, isEmpty);
      expect(restored.first.error, 'Device denied');
      expect(restored.last.profiles, ['other']);
      expect(events.single, first.profiles.toSet());
      expect(prefs.getString('vpn_profile_selected_uri'), isNull);
      expect(restored.first.copyWith(profiles: ['restored']).error, isNull);
      // An older in-flight response or selection save cannot restore denied keys.
      expect(await repo.updateSubscription(first), isFalse);
      expect(await repo.addSubscription(first), isFalse);
      expect(await repo.upsertSubscriptionByUrl(first), isFalse);
      expect((await repo.getSubscription('a'))!.profiles, isEmpty);
    },
  );

  test('failed HTTP request does not modify saved keys', () async {
    final repo = SubscriptionRepository();
    await repo.addSubscription(
      VpnSubscription(
        id: 'a',
        name: 'a',
        url: 'https://example.com/a',
        profiles: ['working'],
      ),
    );
    await expectLater(
      service(
        http.Response('temporary failure', 503),
      ).fetchSubscription('https://example.com/a'),
      throwsA(isA<SubscriptionFetchException>()),
    );
    expect((await repo.getSubscription('a'))!.profiles, ['working']);
  });

  test(
    'manual HTTPS check receives entire full profile, not first outbound',
    () async {
      const channel = MethodChannel('neuravpn/profile_probe');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final original = xraySubscriptionProfile(candidates: 6);
      messenger.setMockMethodCallHandler(channel, (call) async {
        final config = jsonDecode(call.arguments['config'] as String);
        expect(config['outbounds'], original['outbounds']);
        expect(config['routing'], original['routing']);
        expect(config['observatory'], original['observatory']);
        expect(config['fullProfile'], isTrue);
        return {'status': 'available', 'code': 'HTTPS_OK'};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(
        (await AndroidProfileCheckBackend().check(jsonEncode(original))).status,
        ProfileAvailability.available,
      );
    },
  );

  test(
    'bundled Windows binaries validate full auto and TUN bridge configs',
    () async {
      if (!Platform.isWindows) return;
      final link = XrayProfile.fromJson(xraySubscriptionProfile());
      for (final entry in {
        'xray': generateWindowsXrayProxyConfig(link, SplitTunnelConfig()),
        'sing-box': generateWindowsHybridTunConfig(
          SplitTunnelConfig(),
          inboundTag: 'test',
          interfaceName: 'test',
          addresses: ['172.19.0.1/30'],
          useProfileDns: true,
        ),
      }.entries) {
        final file = File('${directory.path}/${entry.key}.json');
        await file.writeAsString(entry.value);
        final result = await Process.run(
          File('assets/bin/${entry.key}.exe').absolute.path,
          [
            if (entry.key == 'xray') ...['run', '-test'] else 'check',
            '-c',
            file.path,
          ],
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }
    },
  );
}
