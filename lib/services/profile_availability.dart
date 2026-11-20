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
    this.workingServers,
    this.totalServers,
  });
  final ProfileAvailability status;

  /// Real HTTPS round trip through the tunnel; the best one for multi-server
  /// profiles.
  final int? elapsedMs;
  final String? code;
  final DateTime? checkedAt;

  /// Set for profiles holding several servers (JSON "Автовыбор").
  final int? workingServers;
  final int? totalServers;

  bool get isTimeout => code == 'TIMEOUT';

  ProfileCheckResult stamped(DateTime at) => ProfileCheckResult(
    status,
    elapsedMs: elapsedMs,
    code: code,
    checkedAt: at,
    workingServers: workingServers,
    totalServers: totalServers,
  );
}

/// One server outbound to probe. Identical servers shared by several profiles
/// (an "Автовыбор" profile repeats the single-server ones) are probed once.
class ProfileProbeTarget {
  const ProfileProbeTarget(this.id, this.outbound);
  final String id;
  final Map<String, dynamic> outbound;
}

class ProfileProbeTargetResult {
  const ProfileProbeTargetResult(
    this.id,
    this.status, {
    this.code,
    this.elapsedMs,
  });
  final String id;
  final ProfileAvailability status;
  final String? code;
  final int? elapsedMs;
}

/// Batch-level outcome. [code] is set when the whole run could not judge the
/// servers (no network, network changed, another VPN owns the route).
class ProfileProbeRunResult {
  const ProfileProbeRunResult({this.code, this.cancelled = false});
  final String? code;
  final bool cancelled;
}

/// Outbound protocols that always leave through a remote server, so a green
/// result can never come from a direct connection.
const _probeProtocols = <String>{
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'hysteria',
};

/// Probe targets for [uris], deduplicated by server settings.
class ProfileProbePlan {
  ProfileProbePlan._(this.targets, this.targetsByUri, this.invalid);

  factory ProfileProbePlan.build(Iterable<String> uris) {
    final targets = <ProfileProbeTarget>[];
    final idsByKey = <String, String>{};
    final targetsByUri = <String, List<String>>{};
    final invalid = <String>{};
    for (final uri in uris) {
      if (targetsByUri.containsKey(uri) || invalid.contains(uri)) continue;
      final outbounds = _probeOutbounds(uri);
      if (outbounds.isEmpty) {
        invalid.add(uri);
        continue;
      }
      final ids = <String>[];
      for (final outbound in outbounds) {
        final key = jsonEncode(<String, dynamic>{...outbound}..remove('tag'));
        final id = idsByKey.putIfAbsent(key, () {
          final id = 't${targets.length}';
          targets.add(ProfileProbeTarget(id, outbound));
          return id;
        });
        if (!ids.contains(id)) ids.add(id);
      }
      targetsByUri[uri] = ids;
    }
    return ProfileProbePlan._(targets, targetsByUri, invalid);
  }

  final List<ProfileProbeTarget> targets;
  final Map<String, List<String>> targetsByUri;
  final Set<String> invalid;

  static List<Map<String, dynamic>> _probeOutbounds(String uri) {
    final link = parseProxyUri(uri);
    if (link == null || proxyValidationError(link) != null) return const [];
    try {
      if (link is XrayProfile) {
        // Every server of an "Автовыбор" profile, not just the primary one.
        return (link.config['outbounds'] as List)
            .whereType<Map>()
            .map(Map<String, dynamic>.from)
            .where((o) => _probeProtocols.contains(o['protocol']))
            .where((o) => !_hasDetour(o))
            .toList();
      }
      // Reuse the real client's transport settings, never its routing bypasses.
      final generated =
          jsonDecode(generateAndroidXrayConfig(link, SplitTunnelConfig()))
              as Map;
      final outbound = Map<String, dynamic>.from(
        (generated['outbounds'] as List).first as Map,
      );
      return _probeProtocols.contains(outbound['protocol']) &&
              !_hasDetour(outbound)
          ? [outbound]
          : const [];
    } catch (_) {
      return const [];
    }
  }

  /// Chained servers need their detour outbound; probing them alone would
  /// report a false failure.
  static bool _hasDetour(Map<String, dynamic> outbound) {
    if (outbound['proxySettings'] != null) return true;
    final stream = outbound['streamSettings'];
    final sockopt = stream is Map ? stream['sockopt'] : null;
    return sockopt is Map && sockopt['dialerProxy'] != null;
  }
}

abstract class ProfileCheckBackend {
  /// Probes [targets] in one run. [onResult] fires as each server finishes.
  Future<ProfileProbeRunResult> run(
    List<ProfileProbeTarget> targets,
    void Function(ProfileProbeTargetResult result) onResult,
  );
  Future<void> cancel();

  /// Lets the worker process go once a run is over.
  Future<void> release() async {}
}

class AndroidProfileCheckBackend extends ProfileCheckBackend {
  static const _channel = MethodChannel('neuravpn/profile_probe');
  static int _runs = 0;

  @override
  Future<ProfileProbeRunResult> run(
    List<ProfileProbeTarget> targets,
    void Function(ProfileProbeTargetResult result) onResult,
  ) async {
    final run = ++_runs;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'result') return;
      final args = Map<String, dynamic>.from(call.arguments as Map);
      if (args['run'] != run) return;
      onResult(parseAndroidProbeResult(args));
    });
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('check', {
        'run': run,
        'targets': jsonEncode([
          for (final target in targets)
            {'id': target.id, 'outbound': target.outbound},
        ]),
      });
      final status = result?['status'];
      return ProfileProbeRunResult(
        cancelled: status == 'cancelled',
        code: status == 'done'
            ? null
            : result?['code'] as String? ?? 'ENGINE_ERROR',
      );
    } on PlatformException catch (error) {
      return ProfileProbeRunResult(code: error.code);
    } finally {
      if (_runs == run) _channel.setMethodCallHandler(null);
    }
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  @override
  Future<void> release() => _channel.invokeMethod<void>('release');
}

/// Only an HTTPS response through the tunnel counts as working; a TCP
/// connect, ping or TLS handshake alone never turns a server green.
@visibleForTesting
ProfileProbeTargetResult parseAndroidProbeResult(Map<String, dynamic> args) {
  final status = switch (args['status']) {
    'available' when args['code'] == 'HTTPS_OK' =>
      ProfileAvailability.available,
    'unavailable' => ProfileAvailability.unavailable,
    'cancelled' => ProfileAvailability.unknown,
    _ => ProfileAvailability.error,
  };
  final elapsed = args['elapsedMs'];
  return ProfileProbeTargetResult(
    '${args['id']}',
    status,
    code: args['code'] as String?,
    elapsedMs: elapsed is int && elapsed > 0 ? elapsed : null,
  );
}

class ProfileAvailabilityController extends ChangeNotifier {
  ProfileAvailabilityController(this.backend, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// How long an observation stays on screen. Long enough to pick a server
  /// after a scan, short enough not to vouch for yesterday's network.
  static const resultLifetime = Duration(minutes: 30);

  final ProfileCheckBackend backend;
  final DateTime Function() _now;
  final Map<String, ProfileCheckResult> _results = {};
  Set<String> _profiles = {};
  bool running = false;
  bool cancelling = false;
  bool _disposed = false;

  /// Group being checked (a subscription id), so only its button turns into
  /// a stop button.
  String? runningScope;

  /// Profiles finished / profiles in the current run.
  int completed = 0;
  int total = 0;

  ProfileCheckResult resultFor(String uri) {
    final result = _results[uri];
    if (result == null ||
        (result.checkedAt != null &&
            _now().difference(result.checkedAt!) > resultLifetime)) {
      return const ProfileCheckResult(ProfileAvailability.unknown);
    }
    return result;
  }

  void setProfiles(Iterable<String> uris) {
    _profiles = uris.toSet();
    _results.removeWhere((uri, _) => !_profiles.contains(uri));
  }

  Future<void> checkAll(Iterable<String> uris, {String? scope}) async {
    if (running || _disposed) return;
    final wanted = uris.where(_profiles.contains).toSet().toList();
    if (wanted.isEmpty) return;
    final plan = ProfileProbePlan.build(wanted);
    running = true;
    cancelling = false;
    runningScope = scope;
    completed = 0;
    total = wanted.length;

    final now = _now();
    for (final uri in plan.invalid) {
      _results[uri] = ProfileCheckResult(
        ProfileAvailability.error,
        code: 'INVALID_CONFIG',
        checkedAt: now,
      );
      completed++;
    }
    for (final uri in plan.targetsByUri.keys) {
      _results[uri] = const ProfileCheckResult(ProfileAvailability.checking);
    }
    notifyListeners();

    final targetResults = <String, ProfileProbeTargetResult>{};
    final open = Set<String>.of(plan.targetsByUri.keys);
    void onResult(ProfileProbeTargetResult result) {
      if (_disposed || cancelling) return;
      targetResults[result.id] = result;
      var changed = false;
      for (final uri in open.toList()) {
        final ids = plan.targetsByUri[uri]!;
        if (!ids.contains(result.id)) continue;
        if (!ids.every(targetResults.containsKey)) continue;
        open.remove(uri);
        completed++;
        changed = true;
        if (_profiles.contains(uri)) {
          _results[uri] = _aggregate([
            for (final id in ids) targetResults[id]!,
          ]).stamped(_now());
        }
      }
      if (changed) notifyListeners();
    }

    ProfileProbeRunResult? outcome;
    try {
      if (plan.targets.isNotEmpty) {
        outcome = await backend.run(plan.targets, onResult);
      }
    } catch (_) {
      outcome = const ProfileProbeRunResult(code: 'CHECK_FAILED');
    } finally {
      final code = outcome?.code;
      final unfinished = cancelling || (outcome?.cancelled ?? false);
      for (final uri in open) {
        // A run that could not judge the network never declares servers dead.
        _results[uri] = unfinished || code == null
            ? const ProfileCheckResult(ProfileAvailability.unknown)
            : ProfileCheckResult(
                ProfileAvailability.error,
                code: code,
                checkedAt: _now(),
              );
      }
      if (code != null && !unfinished && _isNetworkCode(code)) {
        // Failures measured while the network itself was broken are not
        // evidence against the servers.
        for (final uri in plan.targetsByUri.keys) {
          final result = _results[uri];
          if (result?.status == ProfileAvailability.unavailable) {
            _results[uri] = ProfileCheckResult(
              ProfileAvailability.error,
              code: code,
              checkedAt: _now(),
            );
          }
        }
      }
      try {
        await backend.release();
      } catch (_) {
        // Engine detach may have already unbound the native service.
      }
      running = false;
      cancelling = false;
      runningScope = null;
      if (!_disposed) notifyListeners();
    }
  }

  static bool _isNetworkCode(String code) => const {
    'NO_NETWORK',
    'NO_NETWORK_DNS',
    'NETWORK_CHANGED',
    'NETWORK_BIND_FAILED',
  }.contains(code);

  static ProfileCheckResult _aggregate(List<ProfileProbeTargetResult> parts) {
    final working = parts
        .where((p) => p.status == ProfileAvailability.available)
        .toList();
    final multi = parts.length > 1;
    if (working.isNotEmpty) {
      final best = working
          .map((p) => p.elapsedMs)
          .whereType<int>()
          .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
      return ProfileCheckResult(
        ProfileAvailability.available,
        elapsedMs: best,
        code: 'HTTPS_OK',
        workingServers: multi ? working.length : null,
        totalServers: multi ? parts.length : null,
      );
    }
    final judged = parts
        .where((p) => p.status == ProfileAvailability.unavailable)
        .toList();
    if (judged.isEmpty) {
      return ProfileCheckResult(
        ProfileAvailability.error,
        code: parts.first.code ?? 'ENGINE_ERROR',
        workingServers: multi ? 0 : null,
        totalServers: multi ? parts.length : null,
      );
    }
    return ProfileCheckResult(
      ProfileAvailability.unavailable,
      code: judged.every((p) => p.code == 'TIMEOUT')
          ? 'TIMEOUT'
          : 'HTTPS_FAILED',
      workingServers: multi ? 0 : null,
      totalServers: multi ? parts.length : null,
    );
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
