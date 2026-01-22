import 'dart:async';

import '../models/connectivity_test.dart';
import 'cache_repository.dart';
import 'domain_groups.dart';

enum RoutingPath { vpn, direct, directEvasion }

class RoutingDecisionRecord {
  RoutingDecisionRecord({
    required this.path,
    required this.expiresAt,
    required this.stats,
    this.domains = const <String>[],
    this.reason,
  });

  final RoutingPath path;
  final DateTime expiresAt;
  final RoutingStats stats;
  final List<String> domains;
  final String? reason;

  Map<String, dynamic> toJson() => {
        'path': path.name,
        'expires_at': expiresAt.toIso8601String(),
        'stats': stats.toJson(),
        'domains': domains,
        if (reason != null) 'reason': reason,
      };

  static RoutingDecisionRecord? fromJson(Map<dynamic, dynamic> json) {
    try {
      final pathRaw = json['path'];
      final expiresRaw = json['expires_at'];
      final statsRaw = json['stats'];
      if (pathRaw is! String || expiresRaw is! String || statsRaw is! Map) {
        return null;
      }
      final expiresAt = DateTime.tryParse(expiresRaw);
      if (expiresAt == null) return null;
      final path = RoutingPath.values.firstWhere(
        (value) => value.name == pathRaw,
        orElse: () => RoutingPath.vpn,
      );
      final stats = RoutingStats.fromJson(statsRaw) ?? RoutingStats();
      final domains = json['domains'] is List
          ? (json['domains'] as List)
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList()
          : const <String>[];
      final reason = json['reason']?.toString();
      return RoutingDecisionRecord(
        path: path,
        expiresAt: expiresAt,
        stats: stats,
        domains: domains,
        reason: reason,
      );
    } catch (_) {
      return null;
    }
  }
}

class RoutingStats {
  RoutingStats({
    this.vpnSuccess = 0,
    this.vpnFailure = 0,
    this.directSuccess = 0,
    this.directFailure = 0,
    this.directEvasionSuccess = 0,
    this.directEvasionFailure = 0,
    DateTime? lastUpdated,
  }) : lastUpdated = lastUpdated ?? DateTime.now();

  int vpnSuccess;
  int vpnFailure;
  int directSuccess;
  int directFailure;
  int directEvasionSuccess;
  int directEvasionFailure;
  DateTime lastUpdated;

  void markSuccess(RoutingPath path) {
    switch (path) {
      case RoutingPath.vpn:
        vpnSuccess++;
        break;
      case RoutingPath.direct:
        directSuccess++;
        break;
      case RoutingPath.directEvasion:
        directEvasionSuccess++;
        break;
    }
    lastUpdated = DateTime.now();
  }

  void markFailure(RoutingPath path) {
    switch (path) {
      case RoutingPath.vpn:
        vpnFailure++;
        break;
      case RoutingPath.direct:
        directFailure++;
        break;
      case RoutingPath.directEvasion:
        directEvasionFailure++;
        break;
    }
    lastUpdated = DateTime.now();
  }

  Map<String, dynamic> toJson() => {
        'vpn_success': vpnSuccess,
        'vpn_failure': vpnFailure,
        'direct_success': directSuccess,
        'direct_failure': directFailure,
        'direct_evasion_success': directEvasionSuccess,
        'direct_evasion_failure': directEvasionFailure,
        'last_updated': lastUpdated.toIso8601String(),
      };

  static RoutingStats? fromJson(Map<dynamic, dynamic> json) {
    try {
      return RoutingStats(
        vpnSuccess: json['vpn_success'] is int ? json['vpn_success'] as int : 0,
        vpnFailure: json['vpn_failure'] is int ? json['vpn_failure'] as int : 0,
        directSuccess:
            json['direct_success'] is int ? json['direct_success'] as int : 0,
        directFailure:
            json['direct_failure'] is int ? json['direct_failure'] as int : 0,
        directEvasionSuccess: json['direct_evasion_success'] is int
            ? json['direct_evasion_success'] as int
            : 0,
        directEvasionFailure: json['direct_evasion_failure'] is int
            ? json['direct_evasion_failure'] as int
            : 0,
        lastUpdated: DateTime.tryParse(
              json['last_updated']?.toString() ?? '',
            ) ??
            DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}

class RoutingDecisionEngine {
  RoutingDecisionEngine({
    Duration ttl = const Duration(hours: 12),
    CacheRepository? cacheRepository,
    DateTime Function()? clock,
  }) : _ttl = ttl,
       _clock = clock ?? DateTime.now,
       _cacheRepository = cacheRepository ?? CacheRepository();

  final Duration _ttl;
  final DateTime Function() _clock;
  final CacheRepository _cacheRepository;

  final Map<String, Map<String, RoutingDecisionRecord>> _cache = {};
  bool _restored = false;
  Timer? _persistDebounce;

  Future<void> ensureLoaded() async {
    if (_restored) return;
    _restored = true;
    try {
      final loaded = await _cacheRepository.loadSmartRoutingDecisions();
      _cache
        ..clear()
        ..addAll(loaded);
    } catch (_) {
      // ignore cache errors
    }
  }

  Future<RoutingPath> decideForGroup({
    required String networkProfileId,
    required String groupId,
    RoutingPath defaultPath = RoutingPath.vpn,
  }) async {
    await ensureLoaded();
    final existing = _cache[networkProfileId]?[groupId];
    if (existing == null) return defaultPath;
    if (_clock().isAfter(existing.expiresAt)) {
      _cache[networkProfileId]?.remove(groupId);
      return defaultPath;
    }
    return existing.path;
  }

  Future<bool> ingestConnectivityResults({
    required String networkProfileId,
    required Iterable<ConnectivityTestResult> results,
    required DomainGroupResolver resolver,
  }) async {
    await ensureLoaded();
    var changed = false;
    for (final result in results) {
      final groupId = resolver.resolveGroupId(result.domain);
      if (groupId == null) continue;
      final observedPath = _mapRouteToPath(result.route) ??
          await decideForGroup(
        networkProfileId: networkProfileId,
        groupId: groupId,
      );
      changed |= _recordObservation(
        networkProfileId: networkProfileId,
        groupId: groupId,
        path: observedPath,
        result: result,
      );
    }
    if (changed) {
      _schedulePersist();
    }
    return changed;
  }

  Future<Map<String, RoutingDecisionRecord>> decisionsForProfile(
    String networkProfileId,
  ) async {
    await ensureLoaded();
    final map = _cache[networkProfileId] ?? const {};
    final now = _clock();
    final filtered = <String, RoutingDecisionRecord>{};
    for (final entry in map.entries) {
      if (now.isAfter(entry.value.expiresAt)) continue;
      filtered[entry.key] = entry.value;
    }
    return Map<String, RoutingDecisionRecord>.from(filtered);
  }

  Future<RoutingDecisionRecord?> decisionForGroup({
    required String networkProfileId,
    required String groupId,
  }) async {
    await ensureLoaded();
    final record = _cache[networkProfileId]?[groupId];
    if (record == null) return null;
    if (_clock().isAfter(record.expiresAt)) {
      _cache[networkProfileId]?.remove(groupId);
      return null;
    }
    return record;
  }

  Future<bool> setDecision({
    required String networkProfileId,
    required String clusterId,
    required RoutingPath path,
    required List<String> domains,
    String? reason,
    Duration? ttlOverride,
  }) async {
    await ensureLoaded();
    final now = _clock();
    final map = _cache.putIfAbsent(networkProfileId, () => {});
    final existing = map[clusterId];
    final ttl = ttlOverride ??
        (reason == 'bootstrap' ? const Duration(hours: 2) : _ttl);
    final expiry = now.add(ttl);
    if (existing != null && existing.path == path) {
      map[clusterId] = RoutingDecisionRecord(
        path: existing.path,
        expiresAt: expiry,
        stats: existing.stats,
        domains: domains,
        reason: reason ?? existing.reason,
      );
      _schedulePersist();
      return false;
    }

    map[clusterId] = RoutingDecisionRecord(
      path: path,
      expiresAt: expiry,
      stats: existing?.stats ?? RoutingStats(),
      domains: domains,
      reason: reason,
    );
    _schedulePersist();
    return true;
  }

  Future<void> clear({String? networkProfileId}) async {
    await ensureLoaded();
    if (networkProfileId == null) {
      _cache.clear();
    } else {
      _cache.remove(networkProfileId);
    }
    _schedulePersist();
  }

  bool _recordObservation({
    required String networkProfileId,
    required String groupId,
    required RoutingPath path,
    required ConnectivityTestResult result,
  }) {
    final isSuccess = result.status == 'ok';
    final map = _cache.putIfAbsent(networkProfileId, () => {});
    final existing = map[groupId];
    final stats = existing?.stats ?? RoutingStats();

    if (isSuccess) {
      stats.markSuccess(path);
    } else {
      stats.markFailure(path);
    }

    final now = _clock();
    final currentPath = existing?.path ?? RoutingPath.vpn;
    final nextPath = _evaluatePath(currentPath, stats, path, result);

    if (existing == null || nextPath != currentPath) {
      map[groupId] = RoutingDecisionRecord(
        path: nextPath,
        expiresAt: now.add(_ttl),
        stats: stats,
      );
      return true;
    }

    map[groupId] = RoutingDecisionRecord(
      path: currentPath,
      expiresAt: existing.expiresAt,
      stats: stats,
    );
    return false;
  }

  RoutingPath _evaluatePath(
    RoutingPath current,
    RoutingStats stats,
    RoutingPath observedPath,
    ConnectivityTestResult result,
  ) {
    if (result.status == 'ok') {
      return current;
    }

    const vpnFailThreshold = 3;
    const directFailThreshold = 2;

    if (observedPath == RoutingPath.vpn) {
      final total = stats.vpnFailure + stats.vpnSuccess;
      if (stats.vpnFailure >= vpnFailThreshold && total >= vpnFailThreshold) {
        return RoutingPath.directEvasion;
      }
    }

    if (observedPath == RoutingPath.direct) {
      final total = stats.directFailure + stats.directSuccess;
      if (stats.directFailure >= directFailThreshold && total >= directFailThreshold) {
        return RoutingPath.directEvasion;
      }
    }

    return current;
  }


  RoutingPath? _mapRouteToPath(String route) {
    switch (route) {
      case 'bypass':
        return RoutingPath.direct;
      case 'direct-evasion':
        return RoutingPath.directEvasion;
      case 'vpn':
        return RoutingPath.vpn;
      default:
        return null;
    }
  }

  void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(seconds: 1), () async {
      try {
        await _cacheRepository.saveSmartRoutingDecisions(_cache);
      } catch (_) {
        // ignore persistence errors
      }
    });
  }

  void dispose() {
    _persistDebounce?.cancel();
  }
}
