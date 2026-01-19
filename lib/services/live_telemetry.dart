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

  Future<void> _processDnsQuery(String clusterId, String domain) async {
    if (await _applyPolicyDecision(clusterId, domain)) {
      return;
    }

    final existing = await routingDecisionEngine.decisionForGroup(
      networkProfileId: _networkProfileId,
      groupId: clusterId,
    );
    if (existing != null) return;

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
}
