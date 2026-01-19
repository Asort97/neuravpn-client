import 'package:flutter_test/flutter_test.dart';

import 'package:happycat_vpnclient/models/connectivity_test.dart';
import 'package:happycat_vpnclient/services/domain_groups.dart';
import 'package:happycat_vpnclient/services/routing_decision_engine.dart';

class _FakeClock {
  _FakeClock() : _now = DateTime(2024, 1, 1, 0, 0, 0);

  DateTime _now;

  DateTime call() => _now;

  void advance(Duration delta) {
    _now = _now.add(delta);
  }
}

void main() {
  test('vpn failures promote group to direct-evasion', () async {
    final clock = _FakeClock();
    final engine = RoutingDecisionEngine(clock: clock.call);
    final resolver = DomainGroupResolver([
      const DomainGroup(id: 'video', domains: {'youtube.com'}),
    ]);

    for (var i = 0; i < 3; i++) {
      await engine.ingestConnectivityResults(
        networkProfileId: 'default',
        resolver: resolver,
        results: [
          ConnectivityTestResult(
            domain: 'youtube.com',
            status: 'timeout',
            route: 'vpn',
            timestamp: clock.call(),
          ),
        ],
      );
    }

    final decisions = await engine.decisionsForProfile('default');
    expect(decisions['video']?.path, RoutingPath.directEvasion);
  });

  test('direct failure promotes group to direct-evasion', () async {
    final engine = RoutingDecisionEngine();
    final resolver = DomainGroupResolver([
      const DomainGroup(id: 'social', domains: {'vk.com'}),
    ]);

    for (var i = 0; i < 2; i++) {
      await engine.ingestConnectivityResults(
        networkProfileId: 'default',
        resolver: resolver,
        results: [
          ConnectivityTestResult(
            domain: 'vk.com',
            status: 'timeout',
            route: 'bypass',
            timestamp: DateTime.now(),
          ),
        ],
      );
    }

    final decisions = await engine.decisionsForProfile('default');
    expect(decisions['social']?.path, RoutingPath.directEvasion);
  });

  test('setDecision stores domains and reason', () async {
    final engine = RoutingDecisionEngine();
    final changed = await engine.setDecision(
      networkProfileId: 'default',
      clusterId: 'roblox',
      path: RoutingPath.directEvasion,
      domains: ['rbxcdn.com', 'roblox.com'],
      reason: 'probe',
    );
    expect(changed, isTrue);
    final decisions = await engine.decisionsForProfile('default');
    final record = decisions['roblox'];
    expect(record?.path, RoutingPath.directEvasion);
    expect(record?.domains, contains('rbxcdn.com'));
    expect(record?.reason, 'probe');
  });
}
