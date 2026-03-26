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

/// Симулирует логику _expandAppsWithExtras из main.dart.
/// Копия для тестирования — маппинги идентичны тем, что в коде.
const Map<String, List<String>> _appExtraDomainsMap = {
  'valorant.exe': [
    'riotgames.com',
    'riotgames.net',
    'playvalorant.com',
    'riotcdn.net',
    'pvp.net',
    'leagueoflegends.com',
    'lolesports.com',
    'bacon.gg',
    'riotgames.cn',
    'valorantesports.com',
    'riotsecure.com',
  ],
  'riotclientservices.exe': [
    'riotgames.com',
    'riotgames.net',
    'playvalorant.com',
    'riotcdn.net',
    'pvp.net',
    'leagueoflegends.com',
    'riotsecure.com',
  ],
  'vgc.exe': [
    'riotgames.com',
    'riotgames.net',
    'playvalorant.com',
    'riotcdn.net',
    'pvp.net',
    'riotsecure.com',
  ],
  'leagueclient.exe': [
    'riotgames.com',
    'riotgames.net',
    'riotcdn.net',
    'pvp.net',
    'leagueoflegends.com',
    'lolesports.com',
  ],
};

const Map<String, List<String>> _appExtraProcessesMap = {
  'valorant.exe': [
    'VALORANT-Win64-Shipping.exe',
    'RiotClientServices.exe',
    'RiotClientCrashHandler.exe',
    'vgc.exe',
    'vgtray.exe',
    'vgm.exe',
    'log-uploader.exe',
  ],
  'riotclientservices.exe': [
    'VALORANT-Win64-Shipping.exe',
    'RiotClientCrashHandler.exe',
    'vgc.exe',
    'vgtray.exe',
    'vgm.exe',
    'log-uploader.exe',
  ],
  'leagueclient.exe': [
    'LeagueClientUx.exe',
    'League of Legends.exe',
    'RiotClientServices.exe',
    'RiotClientCrashHandler.exe',
    'vgc.exe',
    'vgtray.exe',
    'vgm.exe',
    'log-uploader.exe',
  ],
};

/// Имитирует _expandAppsWithExtras из main.dart
({List<String> apps, List<String> extraDomains}) expandAppsWithExtras(
  List<String> applications,
) {
  final extraDomains = <String>{};
  final extraProcesses = <String>{};
  for (final app in applications) {
    final exeName = app.contains('\\') || app.contains('/')
        ? app.split(RegExp(r'[/\\]')).last.toLowerCase()
        : app.toLowerCase();
    final domains = _appExtraDomainsMap[exeName];
    if (domains != null) extraDomains.addAll(domains);
    final processes = _appExtraProcessesMap[exeName];
    if (processes != null) extraProcesses.addAll(processes);
  }
  final appsLower = applications.map((a) => a.toLowerCase()).toSet();
  final mergedApps = List<String>.from(applications);
  for (final proc in extraProcesses) {
    if (!appsLower.contains(proc.toLowerCase())) {
      mergedApps.add(proc);
    }
  }
  return (apps: mergedApps, extraDomains: extraDomains.toList());
}

void main() {
  group('App expansion — extra domains', () {
    test('valorant.exe adds Riot domains', () {
      final result = expandAppsWithExtras(['VALORANT.exe']);
      expect(result.extraDomains, contains('riotgames.com'));
      expect(result.extraDomains, contains('playvalorant.com'));
      expect(result.extraDomains, contains('pvp.net'));
      expect(result.extraDomains, contains('riotcdn.net'));
      expect(result.extraDomains, contains('riotsecure.com'));
    });

    test('valorant.exe path adds Riot domains', () {
      final result = expandAppsWithExtras([
        r'C:\Riot Games\VALORANT\live\VALORANT.exe',
      ]);
      expect(result.extraDomains, contains('riotgames.com'));
      expect(result.extraDomains, contains('playvalorant.com'));
    });

    test('vgc.exe adds Riot domains', () {
      final result = expandAppsWithExtras(['vgc.exe']);
      expect(result.extraDomains, contains('riotgames.com'));
      expect(result.extraDomains, contains('pvp.net'));
    });

    test('unknown app adds no extra domains', () {
      final result = expandAppsWithExtras(['chrome.exe']);
      expect(result.extraDomains, isEmpty);
    });

    test('multiple Riot apps deduplicate domains', () {
      final result = expandAppsWithExtras([
        'VALORANT.exe',
        'vgc.exe',
        'RiotClientServices.exe',
      ]);
      // Домены должны быть уникальными (Set)
      final domainSet = result.extraDomains.toSet();
      expect(domainSet.length, result.extraDomains.length);
      expect(domainSet, contains('riotgames.com'));
    });
  });

  group('App expansion — extra processes', () {
    test('valorant.exe adds Riot sub-processes', () {
      final result = expandAppsWithExtras(['VALORANT.exe']);
      expect(result.apps, contains('VALORANT.exe'));
      expect(result.apps, contains('vgc.exe'));
      expect(result.apps, contains('vgtray.exe'));
      expect(result.apps, contains('vgm.exe'));
      expect(result.apps, contains('RiotClientServices.exe'));
      expect(result.apps, contains('log-uploader.exe'));
    });

    test('does not duplicate processes already in the list', () {
      final result = expandAppsWithExtras(['VALORANT.exe', 'vgc.exe']);
      final lower = result.apps.map((a) => a.toLowerCase()).toList();
      final vgcCount = lower.where((a) => a == 'vgc.exe').length;
      expect(vgcCount, 1, reason: 'vgc.exe should not be duplicated');
    });

    test('unknown app returns only itself', () {
      final result = expandAppsWithExtras(['notepad.exe']);
      expect(result.apps, ['notepad.exe']);
      expect(result.extraDomains, isEmpty);
    });
  });

  group('Xray config with expanded Valorant', () {
    test('blacklist with Valorant domains produces direct domain rule', () {
      // Симулируем что _configForConnection уже расширил конфиг
      final expansion = expandAppsWithExtras(['VALORANT.exe']);
      final config = jsonDecode(
        generateXrayConfig(
          _parse(
            'vless://$_uuid@example.com:443?security=tls&type=tcp&sni=example.com#proxy',
          ),
          SplitTunnelConfig(
            mode: 'blacklist',
            domains: expansion.extraDomains,
            applications: expansion.apps,
          ),
        ),
      ) as Map<String, dynamic>;

      final routing = config['routing'] as Map<String, dynamic>;
      final rules =
          (routing['rules'] as List<dynamic>).cast<Map<String, dynamic>>();

      // Должно быть правило domain → direct
      final domainRule = rules.firstWhere(
        (r) => r['domain'] != null && r['outboundTag'] == 'direct',
        orElse: () => <String, dynamic>{},
      );
      expect(domainRule, isNotEmpty, reason: 'Should have domain direct rule');
      final domains =
          (domainRule['domain'] as List<dynamic>).map((e) => '$e').toList();
      expect(
        domains.any((d) => d.contains('riotgames.com')),
        isTrue,
        reason: 'riotgames.com should be in direct domains',
      );
      expect(
        domains.any((d) => d.contains('playvalorant.com')),
        isTrue,
        reason: 'playvalorant.com should be in direct domains',
      );

      // Должно быть правило process → direct
      final processRule = rules.firstWhere(
        (r) => r['process'] != null && r['outboundTag'] == 'direct',
        orElse: () => <String, dynamic>{},
      );
      expect(processRule, isNotEmpty,
          reason: 'Should have process direct rule');
      final processes =
          (processRule['process'] as List<dynamic>).map((e) => '$e').toList();
      expect(processes, contains('VALORANT.exe'));
      expect(processes, contains('vgc.exe'));
      expect(processes, contains('vgtray.exe'));
    });

    test('whitelist with Valorant domains produces proxy domain rule', () {
      final expansion = expandAppsWithExtras(['VALORANT.exe']);
      final config = jsonDecode(
        generateXrayConfig(
          _parse(
            'vless://$_uuid@example.com:443?security=tls&type=tcp&sni=example.com#proxy',
          ),
          SplitTunnelConfig(
            mode: 'whitelist',
            domains: expansion.extraDomains,
            applications: expansion.apps,
          ),
        ),
      ) as Map<String, dynamic>;

      final routing = config['routing'] as Map<String, dynamic>;
      final rules =
          (routing['rules'] as List<dynamic>).cast<Map<String, dynamic>>();

      final domainRule = rules.firstWhere(
        (r) => r['domain'] != null && r['outboundTag'] == 'proxy',
        orElse: () => <String, dynamic>{},
      );
      expect(domainRule, isNotEmpty,
          reason: 'Should have domain proxy rule');
    });
  });
}
