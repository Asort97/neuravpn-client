import 'dart:async';

import 'auto_probe_manager.dart';
import 'bootstrap_suspects.dart';
import 'dns_proxy.dart';
import 'live_telemetry_config.dart';
import 'routing_decision_engine.dart';
import 'service_session_builder.dart';
import 'socks_evasion_proxy.dart';
import 'smart_route_engine.dart';

class _ClusterSignals {
  bool suspectDpi = false;
  bool suspectVpnDegrade = false;
  String? lastReason;

  bool get hasSuspect => suspectDpi || suspectVpnDegrade;

  void markDpiSuspect({String? reason}) {
    suspectDpi = true;
    lastReason = reason ?? lastReason;
  }

  void markVpnDegrade({String? reason}) {
    suspectVpnDegrade = true;
    lastReason = reason ?? lastReason;
  }
}

class LiveTelemetryManager {
  LiveTelemetryManager({
    required this.routingDecisionEngine,
    required this.config,
    required this.onDecisionChanged,
    required this.smartRoutingZapretAggressive,
    required this.policyEngine,
    this.policyDecisionTtl = const Duration(hours: 24),
    this.learnedDecisionTtl = const Duration(hours: 18),
  })  : _dnsProxy = config.dnsPort != null
            ? DnsProxy(listenPort: config.dnsPort!)
            : null,
        _sessionBuilder = ServiceSessionBuilder(),
        _probeManager = AutoProbeManager(
          config: ProbeConfig(
            vpnPort: config.probeVpnPort,
            directPort: config.probeDirectPort,
            evasionPort: config.probeEvasionPort,
          ),
          onDecision: (
            ignoredCluster,
            ignoredPath,
            ignoredReason,
          ) {},
        ),
        _evasionProxy = SocksEvasionProxy(
          listenPort: config.evasionProxyPort,
          aggressive: smartRoutingZapretAggressive,
        );

  final RoutingDecisionEngine routingDecisionEngine;
  final LiveTelemetryConfig config;
  final void Function() onDecisionChanged;
  final bool smartRoutingZapretAggressive;
  final SmartRouteEngine policyEngine;
  final Duration policyDecisionTtl;
  final Duration learnedDecisionTtl;

  final DnsProxy? _dnsProxy;
  final ServiceSessionBuilder _sessionBuilder;
  final AutoProbeManager _probeManager;
  final SocksEvasionProxy _evasionProxy;
  BootstrapSuspects? _bootstrap;
  String _networkProfileId = 'default';
  bool _started = false;
  final Map<String, _ClusterSignals> _signals = {};
  final Map<String, List<_ConnEvent>> _clusterEvents = {};
  final Map<String, DateTime> _lastProbe = {};

  Future<bool> start({required String networkProfileId}) async {
    if (_started) return true;
    _networkProfileId = networkProfileId;
    _bootstrap ??= await BootstrapSuspects.load();
    _signals.clear();
    _dnsProxy
      ?..onQuery = _handleDnsQuery
      ..onResult = _handleDnsResult;
    _evasionProxy.onEvent = _handleEvasionEvent;

    _probeManager.onDecision = (clusterId, path, reason) async {
      final domains = _sessionBuilder.domainsForCluster(clusterId).toList();
      if (domains.isEmpty) return;
      final changed = await routingDecisionEngine.setDecision(
        networkProfileId: _networkProfileId,
        clusterId: clusterId,
        path: path,
        domains: domains,
        reason: reason,
        ttlOverride: learnedDecisionTtl,
      );
      if (changed) {
        onDecisionChanged();
      }
    };

    try {
      final dnsProxy = _dnsProxy;
      if (dnsProxy != null) {
        try {
          await dnsProxy.start();
        } catch (_) {
          // If DNS proxy fails, continue without it.
          await dnsProxy.stop();
        }
      }
      await _evasionProxy.start();
      await _probeManager.start();
      _started = true;
      return true;
    } catch (_) {
      await stop();
      return false;
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    await _probeManager.stop();
    await _dnsProxy?.stop();
    await _evasionProxy.stop();
    _signals.clear();
    _clusterEvents.clear();
    _lastProbe.clear();
    _started = false;
  }

  void _handleDnsQuery(DnsEvent event) {
    final domain = event.domain;
    final clusterId = _sessionBuilder.registerDomain(domain);
    unawaited(_processDnsQuery(clusterId, domain));
  }

  void _handleDnsResult(DnsResult event) {
    // Placeholder for future DNS error aggregation.
  }

  void ingestLogLine(String line) {
    final exchangeMatch = RegExp(r'dns: exchange ([^ ]+)\.').firstMatch(line);
    final exchangeFailMatch =
        RegExp(r'dns: exchange failed for ([^ ]+)\. .*?: ([^:]+)$')
            .firstMatch(line);

    String? host;
    bool success = true;
    String? error;

    if (exchangeFailMatch != null) {
      host = exchangeFailMatch.group(1);
      success = false;
      error = exchangeFailMatch.group(2)?.toLowerCase();
    } else if (exchangeMatch != null) {
      host = exchangeMatch.group(1);
      success = true;
    }

    if (host == null || host.isEmpty) return;

    final clusterId = _sessionBuilder.registerDomain(host);
    final now = DateTime.now();
    final events = _clusterEvents.putIfAbsent(clusterId, () => <_ConnEvent>[]);
    events.add(_ConnEvent(
      timestamp: now,
      host: host,
      success: success,
      error: error,
    ));
    _pruneOld(events);

    final clusterStats = _computeClusterStats(events);
    final globalStats = _computeGlobalStats();
    if (_shouldMarkVpnDegrade(clusterStats, globalStats)) {
      _markVpnDegradeAndProbe(clusterId, clusterStats.topHost ?? host);
    }
  }

  Future<void> _processDnsQuery(String clusterId, String domain) async {
    if (await _applyPolicyDecision(clusterId, domain)) {
      return;
    }

    final existing = await routingDecisionEngine.decisionForGroup(
      networkProfileId: _networkProfileId,
      groupId: clusterId,
    );
    if (existing != null && existing.path != RoutingPath.vpn) return;

    final signals = _signalsFor(clusterId);
    if (_bootstrap?.isSuspect(domain) == true) {
      signals.markDpiSuspect(reason: 'bootstrap');
    }

    await _maybeProbe(clusterId, domain, signals);
  }

  Future<bool> _applyPolicyDecision(String clusterId, String domain) async {
    try {
      final decision = await policyEngine.decideForDomain(domain);
      if (decision != RouteDecision.bypassVpn) return false;
      final domains = _sessionBuilder.domainsForCluster(clusterId).toList();
      if (domains.isEmpty) return false;
      final changed = await routingDecisionEngine.setDecision(
        networkProfileId: _networkProfileId,
        clusterId: clusterId,
        path: RoutingPath.direct,
        domains: domains,
        reason: 'policy',
        ttlOverride: policyDecisionTtl,
      );
      if (changed) {
        onDecisionChanged();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _handleEvasionEvent(SocksEvasionEvent event) {
    final clusterId = _sessionBuilder.registerDomain(event.host);
    final signals = _signalsFor(clusterId);
    if (event.success) {
      signals.markDpiSuspect(reason: 'evasion-traffic');
    }
    unawaited(_maybeProbe(clusterId, event.host, signals));
  }

  Future<void> _maybeProbe(
    String clusterId,
    String domain,
    _ClusterSignals signals,
  ) async {
    if (!signals.hasSuspect) return;
    if (await _isSensitiveDomain(domain)) return;

    final existing = await routingDecisionEngine.decisionForGroup(
      networkProfileId: _networkProfileId,
      groupId: clusterId,
    );
    if (existing != null) return;

    final reason = signals.lastReason ?? 'live-suspect';
    _probeManager.enqueue(
      clusterId: clusterId,
      domain: domain,
      reason: reason,
    );
  }

  _ClusterSignals _signalsFor(String clusterId) {
    return _signals.putIfAbsent(clusterId, () => _ClusterSignals());
  }

  Future<bool> _isSensitiveDomain(String domain) async {
    try {
      final decision = await policyEngine.decideForDomain(domain);
      return decision == RouteDecision.bypassVpn;
    } catch (_) {
      return false;
    }
  }

  void _markVpnDegradeAndProbe(String clusterId, String host) {
    final signals = _signalsFor(clusterId);
    signals.markVpnDegrade(reason: 'vpn_degrade');

    final last = _lastProbe[clusterId];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 10)) {
      return;
    }
    _lastProbe[clusterId] = DateTime.now();
    // Debug hook for tracing vpn_degrade decisions.
    // ignore: avoid_print
    print(
      '[telemetry] vpn_degrade detected cluster=$clusterId host=$host '
      'probe scheduled',
    );
    // Ensure zapret/WinDivert is running before we force evasion.
    unawaited(_ensureZapretEvasion());
    // Optimistic override to direct-evasion so content/CDN can recover even if probe fails.
    unawaited(routingDecisionEngine.setDecision(
      networkProfileId: _networkProfileId,
      clusterId: clusterId,
      path: RoutingPath.directEvasion,
      domains: _sessionBuilder.domainsForCluster(clusterId).toList(),
      reason: 'vpn_degrade',
      ttlOverride: const Duration(hours: 4),
    ).then((changed) {
      if (changed) onDecisionChanged();
    }));
    _probeManager.enqueue(
      clusterId: clusterId,
      domain: host,
      reason: 'vpn_degrade',
    );
  }

  Future<void> _ensureZapretEvasion() async {
    try {
      // Best-effort: call back into main via onDecisionChanged hook to re-read decisions and restart VPN core.
      onDecisionChanged();
    } catch (_) {}
  }

  _ClusterStats _computeClusterStats(List<_ConnEvent> events) {
    final now = DateTime.now();
    final windowEvents = events
        .where((e) => now.difference(e.timestamp) <= const Duration(minutes: 5))
        .toList();
    final shortWindow = events
        .where((e) => now.difference(e.timestamp) <= const Duration(seconds: 60))
        .toList();

    final attempts = windowEvents.length;
    final successes = windowEvents.where((e) => e.success).length;
    final failures = attempts - successes;
    final timeouts =
        windowEvents.where((e) => (e.error ?? '').contains('timeout')).length;

    final hostCounts = <String, int>{};
    for (final e in windowEvents) {
      hostCounts.update(e.host, (value) => value + 1, ifAbsent: () => 1);
    }
    String? topHost;
    if (hostCounts.isNotEmpty) {
      topHost = hostCounts.entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;
    }

    final bursts = _countBursts(shortWindow);

    return _ClusterStats(
      attempts: attempts,
      successes: successes,
      failures: failures,
      timeouts: timeouts,
      bursts: bursts,
      topHost: topHost,
    );
  }

  _GlobalStats _computeGlobalStats() {
    final now = DateTime.now();
    var attempts = 0;
    var failures = 0;
    var successes = 0;
    for (final events in _clusterEvents.values) {
      for (final e in events) {
        if (now.difference(e.timestamp) > const Duration(minutes: 5)) continue;
        attempts++;
        if (e.success) {
          successes++;
        } else {
          failures++;
        }
      }
    }
    return _GlobalStats(
      attempts: attempts,
      failures: failures,
      successes: successes,
    );
  }

  bool _shouldMarkVpnDegrade(
    _ClusterStats cluster,
    _GlobalStats global,
  ) {
    if (cluster.attempts < 1) return false;
    final failRate =
        cluster.attempts == 0 ? 0.0 : cluster.failures / cluster.attempts;
    final globalFailRate =
        global.attempts == 0 ? 0.0 : global.failures / global.attempts;

    final thresholdAttempts = 8;
    final failCondition =
        (cluster.attempts >= thresholdAttempts && failRate >= 0.35) ||
            (cluster.timeouts >= 3) ||
            (cluster.bursts >= 2);

    final networkHealthy =
        globalFailRate < 0.15 || global.successes >= 10;

    return failCondition && networkHealthy;
  }

  int _countBursts(List<_ConnEvent> events) {
    if (events.isEmpty) return 0;
    final sorted = List<_ConnEvent>.from(events)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    var bursts = 0;
    var current = <_ConnEvent>[];
    for (final e in sorted) {
      if (current.isEmpty) {
        current.add(e);
        continue;
      }
      final last = current.last;
      if (e.host == last.host &&
          e.timestamp.difference(last.timestamp) <=
              const Duration(seconds: 60)) {
        current.add(e);
      } else {
        if (current.length >= 2) bursts++;
        current = [e];
      }
    }
    if (current.length >= 2) bursts++;
    return bursts;
  }

  void _pruneOld(List<_ConnEvent> events) {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 6));
    events.removeWhere((e) => e.timestamp.isBefore(cutoff));
  }
}

class _ConnEvent {
  _ConnEvent({
    required this.timestamp,
    required this.host,
    required this.success,
    this.error,
  });
  final DateTime timestamp;
  final String host;
  final bool success;
  final String? error;
}

class _ClusterStats {
  _ClusterStats({
    required this.attempts,
    required this.successes,
    required this.failures,
    required this.timeouts,
    required this.bursts,
    required this.topHost,
  });
  final int attempts;
  final int successes;
  final int failures;
  final int timeouts;
  final int bursts;
  final String? topHost;
}

class _GlobalStats {
  _GlobalStats({
    required this.attempts,
    required this.failures,
    required this.successes,
  });
  final int attempts;
  final int failures;
  final int successes;
}
