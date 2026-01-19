import 'dart:async';

import 'routing_decision_engine.dart';
import 'socks_client.dart';

class ProbeConfig {
  ProbeConfig({
    required this.vpnPort,
    required this.directPort,
    required this.evasionPort,
  });

  final int vpnPort;
  final int directPort;
  final int evasionPort;
}

class ProbeResultSummary {
  ProbeResultSummary({
    required this.path,
    required this.success,
    required this.latency,
  });

  final RoutingPath path;
  final bool success;
  final Duration latency;
}

typedef ProbeDecisionCallback = void Function(
  String clusterId,
  RoutingPath path,
  String reason,
);

class AutoProbeManager {
  AutoProbeManager({
    required this.config,
    required this.onDecision,
    this.maxPerMinute = 3,
  });

  final ProbeConfig config;
  ProbeDecisionCallback onDecision;
  final int maxPerMinute;

  final List<_ProbeRequest> _queue = [];
  final Map<String, DateTime> _lastProbe = {};
  Timer? _timer;
  DateTime _windowStart = DateTime.now();
  int _windowCount = 0;

  Future<void> start() async {
    _timer ??= Timer.periodic(const Duration(seconds: 2), (_) => _drain());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _queue.clear();
  }

  void enqueue({
    required String clusterId,
    required String domain,
    required String reason,
  }) {
    final now = DateTime.now();
    final last = _lastProbe[clusterId];
    if (last != null && now.difference(last) < const Duration(minutes: 5)) {
      return;
    }
    _queue.add(
      _ProbeRequest(clusterId: clusterId, domain: domain, reason: reason),
    );
    _lastProbe[clusterId] = now;
  }

  Future<void> _drain() async {
    if (_queue.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_windowStart) > const Duration(minutes: 1)) {
      _windowStart = now;
      _windowCount = 0;
    }
    if (_windowCount >= maxPerMinute) return;
    final request = _queue.removeAt(0);
    _windowCount++;

    final best = await _runProbe(request.domain);
    if (best != null && best.success) {
      onDecision(request.clusterId, best.path, request.reason);
    }
  }

  Future<ProbeResultSummary?> _runProbe(String domain) async {
    final vpnClient = SocksClient(host: '127.0.0.1', port: config.vpnPort);
    final directClient = SocksClient(host: '127.0.0.1', port: config.directPort);
    final evasionClient = SocksClient(host: '127.0.0.1', port: config.evasionPort);

    final results = await Future.wait([
      vpnClient.probeTls(domain, 443),
      evasionClient.probeTls(domain, 443),
      directClient.probeTls(domain, 443),
    ]);

    final mapping = <RoutingPath, ProbeResult>{
      RoutingPath.vpn: results[0],
      RoutingPath.directEvasion: results[1],
      RoutingPath.direct: results[2],
    };

    final successes = mapping.entries.where((entry) => entry.value.success).toList()
      ..sort((a, b) => a.value.latency.compareTo(b.value.latency));

    if (successes.isEmpty) return null;

    final best = successes.first;
    return ProbeResultSummary(
      path: best.key,
      success: true,
      latency: best.value.latency,
    );
  }
}

class _ProbeRequest {
  _ProbeRequest({
    required this.clusterId,
    required this.domain,
    required this.reason,
  });

  final String clusterId;
  final String domain;
  final String reason;
}
