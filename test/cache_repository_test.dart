import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:happycat_vpnclient/models/connectivity_test.dart';
import 'package:happycat_vpnclient/services/cache_repository.dart';
import 'package:happycat_vpnclient/services/smart_route_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('connectivity cache save/load preserves latest results', () async {
    final repo = CacheRepository();
    final now = DateTime.now();

    final results = <String, ConnectivityTestResult>{
      'example.com': ConnectivityTestResult(
        domain: 'example.com',
        status: 'ok',
        route: 'vpn',
        durationMs: 120,
        httpStatus: 200,
        timestamp: now,
      ),
      'example.org': ConnectivityTestResult(
        domain: 'example.org',
        status: 'timeout',
        route: 'vpn',
        error: 'timeout',
        durationMs: 1200,
        timestamp: now.subtract(const Duration(seconds: 5)),
      ),
    };

    await repo.saveConnectivityResults(results);
    final restored = await repo.loadConnectivityResults();

    expect(restored.length, 2);
    expect(restored['example.com']?.status, 'ok');
    expect(restored['example.org']?.status, 'timeout');
  });

  test('route cache skips expired entries on load', () async {
    final repo = CacheRepository();
    final now = DateTime.now();

    await repo.saveRouteDecisions({
      'fresh.com': RouteCacheRecord(
        decision: 'vpn',
        expiresAt: now.add(const Duration(minutes: 10)),
      ),
      'old.com': RouteCacheRecord(
        decision: 'bypass',
        expiresAt: now.subtract(const Duration(minutes: 1)),
      ),
    });

    final restored = await repo.loadRouteDecisions();
    expect(restored.length, 1);
    expect(restored['fresh.com']?.decision, 'vpn');
    expect(restored.containsKey('old.com'), isFalse);
  });

  test('smart route engine restores and uses persisted decision', () async {
    final repo = CacheRepository();
    final now = DateTime.now();
    await repo.saveRouteDecisions({
      'example.com': RouteCacheRecord(
        decision: 'bypass',
        expiresAt: now.add(const Duration(minutes: 5)),
      ),
      'expired.com': RouteCacheRecord(
        decision: 'vpn',
        expiresAt: now.subtract(const Duration(minutes: 1)),
      ),
    });

    final engine = SmartRouteEngine(
      cacheRepository: repo,
      clock: () => now,
    );

    final decision = await engine.decideForDomain('example.com');
    expect(decision, RouteDecision.bypassVpn);

    final decisionExpired = await engine.decideForDomain('expired.com');
    expect(decisionExpired, RouteDecision.useVpn); // fallback logic for .com
  });

  test('smart route engine persists new decisions', () async {
    final repo = CacheRepository();
    final engine = SmartRouteEngine(
      cacheRepository: repo,
      clock: () => DateTime.now(),
    );

    // No preloaded cache; decision will be computed and then persisted.
    final decision = await engine.decideForDomain('example.com');
    expect(decision, RouteDecision.useVpn);

    // Дебаунс записи 1 секунда.
    await Future.delayed(const Duration(milliseconds: 1200));

    final stored = await repo.loadRouteDecisions();
    expect(stored['example.com']?.decision, 'vpn');
  });
}
