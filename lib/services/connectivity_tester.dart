import 'dart:async';
import 'dart:io';

import '../models/connectivity_test.dart';
import '../services/cache_repository.dart';
import '../services/smart_route_engine.dart';

class ConnectivityTester {
  ConnectivityTester({
    this.maxConcurrency = 20,
    this.timeout = const Duration(milliseconds: 1200),
    this.maxAttempts = 2,
    DateTime Function()? clock,
    SmartRouteEngine? routeEngine,
    CacheRepository? cacheRepository,
  }) : _clock = clock ?? DateTime.now,
       _routeEngine = routeEngine ?? SmartRouteEngine(cacheRepository: cacheRepository),
       _cacheRepository = cacheRepository ?? CacheRepository();

  final int maxConcurrency;
  final Duration timeout;
  final int maxAttempts;
  final DateTime Function() _clock;
  final SmartRouteEngine _routeEngine;
  final Map<String, _CachedResult> _cache = {};
  final CacheRepository _cacheRepository;

  bool _restoredFromDisk = false;
  Timer? _persistDebounce;
  Timer? _backgroundRefresh;

  Map<String, ConnectivityTestResult> get cache =>
      _cache.map((key, value) => MapEntry(key, value.result));

  void clearCache() {
    _cache.clear();
    _backgroundRefresh?.cancel();
    _backgroundRefresh = null;
  }

  Future<Map<String, ConnectivityTestResult>> run(
    List<ConnectivityTestTarget> targets, {
    Duration cacheTtl = const Duration(minutes: 30),
    void Function(int completed, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    await _restoreCacheIfNeeded(cacheTtl);

    final results = <String, ConnectivityTestResult>{};
    final tasks = <Future<void>>[];
    var completed = 0;

    for (final target in targets) {
      if (isCancelled?.call() == true) break;

      final cached = _cache[target.domain];
      if (cached != null && _clock().difference(cached.timestamp) <= cacheTtl) {
        results[target.domain] = cached.result;
        completed++;
        onProgress?.call(completed, targets.length);
        continue;
      }

      final future = _runSingle(target)
          .then((result) {
            results[target.domain] = result;
            _cache[target.domain] = _CachedResult(result, result.timestamp);
            _schedulePersist(cacheTtl);
          })
          .whenComplete(() {
            completed++;
            onProgress?.call(completed, targets.length);
          });

      tasks.add(future);
      if (tasks.length >= maxConcurrency) {
        await tasks.first;
        tasks.removeAt(0);
      }
    }

    await Future.wait(tasks);
    _scheduleBackgroundRefresh(targets, cacheTtl);
    return results;
  }

  Future<ConnectivityTestResult> _runSingle(
    ConnectivityTestTarget target,
  ) async {
    final stopwatch = Stopwatch()..start();
    String status = 'routing_error';
    String? error;
    int? httpStatus;

    String route = 'vpn';
    try {
      final routeDecision = await _routeEngine.decideForDomain(target.domain);
      route = routeDecision == RouteDecision.bypassVpn ? 'bypass' : 'vpn';
    } catch (_) {}

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final addresses = await InternetAddress.lookup(target.domain).timeout(
          timeout,
          onTimeout: () => throw TimeoutException('dns_timeout'),
        );
        if (addresses.isEmpty) {
          status = 'dns_error';
          error = 'no_address';
        } else {
          final client = HttpClient();
          client.connectionTimeout = timeout;
          client.badCertificateCallback = (cert, host, port) => false;
          try {
            final request = await client
                .getUrl(Uri.https(target.domain, '/'))
                .timeout(
                  timeout,
                  onTimeout: () => throw TimeoutException('connect_timeout'),
                );
            final response = await request.close().timeout(
              timeout,
              onTimeout: () => throw TimeoutException('read_timeout'),
            );
            httpStatus = response.statusCode;
            status = response.statusCode >= 200 && response.statusCode < 400
                ? 'ok'
                : 'http_error';
          } on HandshakeException catch (e) {
            status = 'ssl_error';
            error = e.toString();
          } on TimeoutException catch (e) {
            status = 'timeout';
            error = e.message ?? 'timeout';
          } on SocketException catch (e) {
            final message = e.message.toLowerCase();
            if (message.contains('refused')) {
              status = 'connection_refused';
            } else if (message.contains('host lookup')) {
              status = 'dns_error';
            } else {
              status = 'network_error';
            }
            error = e.message;
          } catch (e) {
            status = 'routing_error';
            error = e.toString();
          } finally {
            client.close(force: true);
          }
        }
      } on TimeoutException catch (e) {
        status = 'timeout';
        error = e.message ?? 'timeout';
      } on SocketException catch (e) {
        status = 'dns_error';
        error = e.message;
      } catch (e) {
        status = 'routing_error';
        error = e.toString();
      }

      final shouldRetry = status == 'timeout' ||
          status == 'dns_error' ||
          status == 'network_error';
      if (!shouldRetry || attempt == maxAttempts) {
        break;
      }
    }

    stopwatch.stop();
    final durationMs = stopwatch.elapsedMilliseconds;
    return ConnectivityTestResult(
      domain: target.domain,
      status: status,
      error: error,
      durationMs: durationMs,
      route: route,
      httpStatus: httpStatus,
      timestamp: _clock(),
    );
  }

  Future<void> _restoreCacheIfNeeded(Duration cacheTtl) async {
    if (_restoredFromDisk) return;
    _restoredFromDisk = true;
    try {
      final stored = await _cacheRepository.loadConnectivityResults();
      final now = _clock();
      stored.forEach((domain, result) {
        if (now.difference(result.timestamp) <= cacheTtl) {
          _cache[domain] = _CachedResult(result, result.timestamp);
        }
      });
    } catch (_) {
      // Пропускаем ошибки чтения кеша, чтобы не мешать подключению.
    }
  }

  void _schedulePersist(Duration cacheTtl) {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(seconds: 1), () async {
      final now = _clock();
      final filtered = <String, ConnectivityTestResult>{};
      _cache.forEach((domain, entry) {
        if (now.difference(entry.timestamp) <= cacheTtl) {
          filtered[domain] = entry.result;
        }
      });
      if (filtered.isEmpty) return;
      try {
        await _cacheRepository.saveConnectivityResults(filtered);
      } catch (_) {
        // Игнорируем ошибки записи, чтобы не ломать основной поток.
      }
    });
  }

  void _scheduleBackgroundRefresh(
    List<ConnectivityTestTarget> targets,
    Duration cacheTtl,
  ) {
    _backgroundRefresh?.cancel();
    // Обновляем кеш за 5 минут до истечения TTL
    final refreshInterval = cacheTtl - const Duration(minutes: 5);
    if (refreshInterval.inSeconds < 60) return; // Слишком короткий TTL

    _backgroundRefresh = Timer.periodic(refreshInterval, (_) async {
      final now = _clock();
      final staleTargets = <ConnectivityTestTarget>[];

      for (final target in targets) {
        final cached = _cache[target.domain];
        if (cached != null &&
            now.difference(cached.timestamp) > refreshInterval) {
          staleTargets.add(target);
        }
      }

      if (staleTargets.isEmpty) return;

      // Тихое фоновое обновление без коллбэков прогресса
      for (final target in staleTargets) {
        unawaited(_runSingle(target).then((result) {
          _cache[target.domain] = _CachedResult(result, result.timestamp);
          _schedulePersist(cacheTtl);
        }));
      }
    });
  }

  void dispose() {
    _persistDebounce?.cancel();
    _backgroundRefresh?.cancel();
  }
}

class _CachedResult {
  _CachedResult(this.result, this.timestamp);
  final ConnectivityTestResult result;
  final DateTime timestamp;
}
