import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/profile_availability.dart';
import 'package:happycat_vpnclient/services/windows_profile_check.dart';
import 'package:happycat_vpnclient/services/windows_route_manager.dart';

import 'support/xray_subscription.dart';

void main() {
  final plan = ProfileProbePlan.build([
    jsonEncode(xraySubscriptionProfile(candidates: 3)),
  ]);

  test('each local port reaches exactly one server over the uplink', () {
    final ports = [for (var i = 0; i < plan.targets.length; i++) 20000 + i];
    final config =
        jsonDecode(
              buildWindowsProbeConfig(
                plan.targets,
                ports,
                interfaceName: 'Ethernet',
                bindAddress: '192.168.0.2',
              ),
            )
            as Map<String, dynamic>;
    final inbounds = (config['inbounds'] as List).cast<Map>();
    final outbounds = (config['outbounds'] as List).cast<Map>();
    final rules = ((config['routing'] as Map)['rules'] as List).cast<Map>();
    expect(inbounds, hasLength(plan.targets.length));
    for (var i = 0; i < plan.targets.length; i++) {
      expect(inbounds[i]['listen'], '127.0.0.1');
      expect(inbounds[i]['port'], ports[i]);
      expect(rules[i]['inboundTag'], ['probe-in-$i']);
      expect(rules[i]['outboundTag'], 'probe-out-$i');
      expect(outbounds[i]['protocol'], plan.targets[i].outbound['protocol']);
      expect(outbounds[i]['sendThrough'], '192.168.0.2');
      expect(outbounds[i]['streamSettings']['sockopt'], {
        'interface': 'Ethernet',
      });
    }
    // Nothing unmatched may go direct.
    expect(outbounds.last['protocol'], 'blackhole');
    expect(rules.last['outboundTag'], outbounds.last['tag']);
    expect(outbounds.where((o) => o['protocol'] == 'freedom'), isEmpty);
    expect((config['log'] as Map)['loglevel'], 'none');
    // The source profile is never modified.
    expect(plan.targets.first.outbound.containsKey('sendThrough'), isFalse);
  });

  test('bundled Windows Xray accepts the probe config', () async {
    if (!Platform.isWindows) return;
    final tmp = await Directory.systemTemp.createTemp('neura_probe_test_');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File('${tmp.path}/probe.json')
      ..writeAsStringSync(
        buildWindowsProbeConfig(plan.targets, [
          for (var i = 0; i < plan.targets.length; i++) 21000 + i,
        ], interfaceName: 'Ethernet'),
      );
    final result = await Process.run(
      File('assets/bin/xray.exe').absolute.path,
      ['run', '-test', '-c', file.path],
    );
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test('missing network or core is reported, not probed', () async {
    final results = <ProfileProbeTargetResult>[];
    final noNetwork = await WindowsProfileCheckBackend(
      resolveXray: () async => 'xray.exe',
      discoverUplink: () async => null,
    ).run(plan.targets, results.add);
    expect(noNetwork.code, 'NO_NETWORK');
    final noCore = await WindowsProfileCheckBackend(
      resolveXray: () async => null,
      discoverUplink: () async => const WindowsRouteUplink(
        interfaceName: 'Ethernet',
        interfaceIndex: 1,
        gateway: '192.168.0.1',
        localAddress: '192.168.0.2',
      ),
    ).run(plan.targets, results.add);
    expect(noCore.code, 'ENGINE_ERROR');
    expect(results, isEmpty);
  });
}
