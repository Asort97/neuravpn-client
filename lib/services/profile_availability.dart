import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/split_tunnel_config.dart';
import '../vless/config_generator.dart';
import '../vless/proxy_parser.dart';

enum ProfileAvailability {
  unknown,
  queued,
  checking,
  available,
  unavailable,
  error,
}

class ProfileCheckResult {
  const ProfileCheckResult(
    this.status, {
    this.elapsedMs,
    this.code,
    this.checkedAt,
  });
  final ProfileAvailability status;
  final int? elapsedMs;
  final String? code;
  final DateTime? checkedAt;
}

abstract class ProfileCheckBackend {
  Future<ProfileCheckResult> check(String uri);
  Future<void> cancel();
  Future<void> release() async {}
}

class AndroidProfileCheckBackend extends ProfileCheckBackend {
  static const _channel = MethodChannel('neuravpn/profile_probe');

  @override
  Future<ProfileCheckResult> check(String uri) async {
    final link = parseProxyUri(uri);
    if (link == null || proxyValidationError(link) != null) {
      return const ProfileCheckResult(
        ProfileAvailability.error,
        code: 'INVALID_CONFIG',
      );
    }
    // Reuse the real client's transport settings, but never its routing bypasses.
    final generated =
        jsonDecode(generateAndroidXrayConfig(link, SplitTunnelConfig())) as Map;
    final config = jsonEncode({
      'outbounds': [(generated['outbounds'] as List).first],
    });
    final result = await _channel.invokeMapMethod<String, dynamic>('check', {
      'config': config,
    });
    final status = switch (result?['status']) {
      'available' when result?['code'] == 'HTTPS_OK' =>
        ProfileAvailability.available,
      'unavailable' => ProfileAvailability.unavailable,
      'cancelled' => ProfileAvailability.unknown,
      _ => ProfileAvailability.error,
    };
    return ProfileCheckResult(
      status,
      code: result?['code'] as String?,
      elapsedMs: result?['elapsedMs'] as int?,
    );
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  @override
  Future<void> release() => _channel.invokeMethod<void>('release');
}

class ProfileAvailabilityController extends ChangeNotifier {
  ProfileAvailabilityController(this.backend, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final ProfileCheckBackend backend;
  final DateTime Function() _now;
  final Map<String, ProfileCheckResult> _results = {};
  Set<String> _profiles = {};
  bool running = false;
  bool cancelling = false;
  bool _disposed = false;
  int completed = 0;
  int total = 0;

  ProfileCheckResult resultFor(String uri) {
    final result = _results[uri];
    // Availability is a recent observation, not a permanent guarantee.
    if (result == null ||
        (result.checkedAt != null &&
            _now().difference(result.checkedAt!) >
                const Duration(minutes: 5))) {
      return const ProfileCheckResult(ProfileAvailability.unknown);
    }
    return result;
  }

  void setProfiles(Iterable<String> uris) {
    _profiles = uris.toSet();
    _results.removeWhere((uri, _) => !_profiles.contains(uri));
  }

  Future<void> checkAll() async {
    if (running || _disposed || _profiles.isEmpty) return;
    final snapshot = _profiles.toList(growable: false);
    running = true;
    cancelling = false;
    completed = 0;
    total = snapshot.length;
    for (final uri in snapshot) {
      _results[uri] = const ProfileCheckResult(ProfileAvailability.queued);
    }
    notifyListeners();
    try {
      for (final uri in snapshot) {
        if (_disposed || cancelling) break;
        if (!_profiles.contains(uri)) {
          completed++;
          continue;
        }
        _results[uri] = const ProfileCheckResult(ProfileAvailability.checking);
        notifyListeners();
        ProfileCheckResult result;
        try {
          result = await backend.check(uri);
        } catch (_) {
          result = const ProfileCheckResult(
            ProfileAvailability.error,
            code: 'CHECK_FAILED',
          );
        }
        if (_disposed || cancelling) break;
        if (_profiles.contains(uri)) {
          _results[uri] = ProfileCheckResult(
            result.status,
            elapsedMs: result.elapsedMs,
            code: result.code,
            checkedAt: _now(),
          );
        }
        completed++;
        notifyListeners();
        if (const {
          'NO_NETWORK',
          'NO_NETWORK_DNS',
          'NETWORK_CHANGED',
          'NETWORK_BIND_FAILED',
          'WORKER_TIMEOUT',
          'WORKER_STOPPED',
          'WORKER_UNAVAILABLE',
        }.contains(result.code)) {
          break;
        }
      }
    } finally {
      try {
        await backend.release();
      } catch (_) {
        // Engine detach may have already unbound the native service.
      }
      _results.updateAll(
        (_, result) =>
            result.status == ProfileAvailability.queued ||
                result.status == ProfileAvailability.checking
            ? const ProfileCheckResult(ProfileAvailability.unknown)
            : result,
      );
      running = false;
      cancelling = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> cancel() async {
    if (!running || cancelling) return;
    cancelling = true;
    if (!_disposed) notifyListeners();
    try {
      await backend.cancel();
    } catch (_) {
      /* Worker timeout also releases the scan. */
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(cancel());
    super.dispose();
  }
}
