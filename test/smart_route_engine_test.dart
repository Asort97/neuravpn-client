import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/smart_route_engine.dart';

class _FakeClock {
  _FakeClock() : _now = DateTime(2024, 1, 1, 0, 0, 0);

  DateTime _now;

  DateTime call() => _now;

  void advance(Duration delta) {
    _now = _now.add(delta);
  }
}

void main() {
  SmartRouteEngine buildEngine({Duration? ttl, _FakeClock? clock}) {
    final fakeClock = clock ?? _FakeClock();
    return SmartRouteEngine(
      domainCacheTtl: ttl ?? const Duration(minutes: 30),
      clock: fakeClock.call,
    );
  }

  test('anycast mix prefers RU hit', () async {
    final engine = buildEngine();
    final decision = await engine.decideForDomain('cdn.anycast.test');
    expect(decision, RouteDecision.useVpn);
  });

  test('non-RU domain on RU ASN bypasses VPN', () async {
    final engine = buildEngine();
    final decision = await engine.decideForDomain('example.com');
    expect(decision, RouteDecision.useVpn);
  });

  test('RU TLD bypasses even with non-RU IP', () async {
    final engine = buildEngine();
    final decision = await engine.decideForDomain('example.ru');

    expect(decision, RouteDecision.bypassVpn);
  });

  test('unknown domain with unknown IP defaults to VPN', () async {
    final engine = buildEngine();
    final decision = await engine.decideForDomain('unknown.example');

    expect(decision, RouteDecision.useVpn);
  });

  test('domain cache respects TTL and refreshes decisions', () async {
    final clock = _FakeClock();
    final engine = buildEngine(ttl: const Duration(seconds: 1), clock: clock);

    final firstDecision = await engine.decideForDomain('cached.test');
    expect(firstDecision, RouteDecision.useVpn);

    // Add a RU TLD dynamically so the cached decision should flip only after TTL.
    engine.ruTlds.add('test');

    clock.advance(const Duration(milliseconds: 500));
    final cachedDecision = await engine.decideForDomain('cached.test');
    expect(cachedDecision, RouteDecision.useVpn);

    clock.advance(const Duration(seconds: 1));
    final refreshedDecision = await engine.decideForDomain('cached.test');
    expect(refreshedDecision, RouteDecision.bypassVpn);
  });

  test('adds bundled whitelist entries as direct suffix rules', () async {
    final engine = SmartRouteEngine(
      ruTlds: const {},
      russianServices: const {},
    );

    final added = engine.addRussianServicesFromText('''
      alfabank.ru
      sun1-13.userapi.com   
      .mos.ru
      domain:nalog.gov.ru
      # comment
      alfabank.ru
    ''');

    expect(added, 4);
    expect(
      await engine.decideForDomain('pay.alfabank.ru'),
      RouteDecision.bypassVpn,
    );
    expect(
      await engine.decideForDomain('cdn.sun1-13.userapi.com'),
      RouteDecision.bypassVpn,
    );

    final rules = engine.buildRouteRules(outboundTag: 'direct');
    final suffixes = (rules.single['domain_suffix'] as List<String>).toSet();
    expect(suffixes, containsAll(['alfabank.ru', 'mos.ru', 'nalog.gov.ru']));
    expect(rules.single['domain'], isNull);
  });
}
