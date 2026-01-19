import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/connectivity_test.dart';
import 'routing_decision_engine.dart';

class CacheRepository {
  CacheRepository({SharedPreferences? prefs})
      : _prefsFuture = prefs != null
            ? Future.value(prefs)
            : SharedPreferences.getInstance();

  final Future<SharedPreferences> _prefsFuture;

  static const _connectivityKey = 'connectivity_cache_v1';
  static const _routeKey = 'route_cache_v1';
  static const _smartRoutingDecisionKey = 'smart_routing_decisions_v1';
  static const _maxEntries = 512;

  Future<Map<String, ConnectivityTestResult>> loadConnectivityResults() async {
    try {
      final prefs = await _prefsFuture;
      final raw = prefs.getString(_connectivityKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};

      final now = DateTime.now();
      final map = <String, ConnectivityTestResult>{};
      decoded.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final result = _parseConnectivityResult(value, key);
        if (result == null) return;
        // Фильтрация будущих дат и явных мусорных значений.
        if (result.timestamp.isAfter(now.add(const Duration(minutes: 5)))) {
          return;
        }
        map[key] = result;
      });
      return map;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveConnectivityResults(
    Map<String, ConnectivityTestResult> cache,
  ) async {
    try {
      final prefs = await _prefsFuture;
      if (cache.isEmpty) {
        await prefs.remove(_connectivityKey);
        return;
      }

      // Сортируем по времени (новые вперёд) и обрезаем.
      final sorted = cache.entries.toList()
        ..sort((a, b) =>
            (b.value.timestamp).compareTo(a.value.timestamp));
      final limited = sorted.take(_maxEntries);

      final serializable = <String, Map<String, dynamic>>{};
      for (final entry in limited) {
        serializable[entry.key] = entry.value.toJson();
      }
      await prefs.setString(_connectivityKey, jsonEncode(serializable));
    } catch (_) {
      // Тихое игнорирование ошибок хранения, чтобы не ломать подключение.
    }
  }

  Future<Map<String, RouteCacheRecord>> loadRouteDecisions() async {
    try {
      final prefs = await _prefsFuture;
      final raw = prefs.getString(_routeKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};

      final now = DateTime.now();
      final map = <String, RouteCacheRecord>{};
      decoded.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final record = RouteCacheRecord.fromJson(value);
        if (record == null) return;
        if (now.isAfter(record.expiresAt)) return;
        map[key] = record;
      });
      return map;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveRouteDecisions(
    Map<String, RouteCacheRecord> cache,
  ) async {
    try {
      final prefs = await _prefsFuture;
      if (cache.isEmpty) {
        await prefs.remove(_routeKey);
        return;
      }

      final serializable = <String, Map<String, dynamic>>{};
      cache.forEach((key, value) {
        serializable[key] = value.toJson();
      });

      await prefs.setString(_routeKey, jsonEncode(serializable));
    } catch (_) {
      // Игнорируем ошибки записи.
    }
  }


  Future<Map<String, Map<String, RoutingDecisionRecord>>>
      loadSmartRoutingDecisions() async {
    try {
      final prefs = await _prefsFuture;
      final raw = prefs.getString(_smartRoutingDecisionKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};

      final now = DateTime.now();
      final result = <String, Map<String, RoutingDecisionRecord>>{};
      decoded.forEach((profileId, value) {
        if (profileId is! String || value is! Map) return;
        final map = <String, RoutingDecisionRecord>{};
        value.forEach((groupId, recordRaw) {
          if (groupId is! String || recordRaw is! Map) return;
          final record = RoutingDecisionRecord.fromJson(recordRaw);
          if (record == null) return;
          if (now.isAfter(record.expiresAt)) return;
          map[groupId] = record;
        });
        if (map.isNotEmpty) {
          result[profileId] = map;
        }
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveSmartRoutingDecisions(
    Map<String, Map<String, RoutingDecisionRecord>> cache,
  ) async {
    try {
      final prefs = await _prefsFuture;
      if (cache.isEmpty) {
        await prefs.remove(_smartRoutingDecisionKey);
        return;
      }

      final serializable = <String, Map<String, dynamic>>{};
      cache.forEach((profileId, map) {
        serializable[profileId] = {
          for (final entry in map.entries) entry.key: entry.value.toJson(),
        };
      });

      await prefs.setString(
        _smartRoutingDecisionKey,
        jsonEncode(serializable),
      );
    } catch (_) {
      // ignore persistence errors
    }
  }

  ConnectivityTestResult? _parseConnectivityResult(Map<dynamic, dynamic> json, String domain) {
    try {
      final status = json['status'];
      final route = json['route'];
      final timestampRaw = json['timestamp'];
      if (status is! String || route is! String || timestampRaw is! String) {
        return null;
      }
      final timestamp = DateTime.tryParse(timestampRaw);
      if (timestamp == null) return null;

      final durationMs = json['time_ms'];
      final httpStatus = json['http_status'];
      final error = json['error'];

      final domainRaw = json['domain'];

      return ConnectivityTestResult(
        domain: domainRaw is String && domainRaw.isNotEmpty ? domainRaw : domain,
        status: status,
        route: route,
        timestamp: timestamp,
        durationMs: durationMs is int ? durationMs : null,
        httpStatus: httpStatus is int ? httpStatus : null,
        error: error is String ? error : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class RouteCacheRecord {
  RouteCacheRecord({required this.decision, required this.expiresAt});

  final String decision; // 'bypass' | 'vpn'
  final DateTime expiresAt;

  Map<String, dynamic> toJson() => {
        'decision': decision,
        'expires_at': expiresAt.toIso8601String(),
      };

  static RouteCacheRecord? fromJson(Map<dynamic, dynamic> json) {
    try {
      final decisionRaw = json['decision'];
      final expiresRaw = json['expires_at'];
      if (decisionRaw is! String || expiresRaw is! String) return null;
      final expiresAt = DateTime.tryParse(expiresRaw);
      if (expiresAt == null) return null;
      if (decisionRaw != 'bypass' && decisionRaw != 'vpn') return null;
      return RouteCacheRecord(decision: decisionRaw, expiresAt: expiresAt);
    } catch (_) {
      return null;
    }
  }
}
