import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'profile_availability.dart';
import 'vpn_core_binary_manager.dart';
import 'windows_route_manager.dart';

/// Same endpoints and rule as Android: only an HTTPS 204 counts as working.
const _endpoints = <String>[
  'https://www.gstatic.com/generate_204',
  'https://cp.cloudflare.com/generate_204',
];
const _parallel = 10;
const _timeout = Duration(seconds: 5);
const _batchLimit = Duration(seconds: 170);

/// One core for the whole batch: inbound `probe-in-i` on [ports][i] is routed
/// only to outbound `probe-out-i`, so every request measures exactly one
/// server. Every server socket leaves through the physical uplink, never
/// through our own or another VPN; anything unmatched is dropped.
@visibleForTesting
String buildWindowsProbeConfig(
  List<ProfileProbeTarget> targets,
  List<int> ports, {
  String? interfaceName,
  String? bindAddress,
}) {
  if (targets.isEmpty || targets.length != ports.length) {
    throw ArgumentError('one port per target');
  }
  final inbounds = <Map<String, dynamic>>[];
  final outbounds = <Map<String, dynamic>>[];
  final rules = <Map<String, dynamic>>[];
  for (var i = 0; i < targets.length; i++) {
    final outbound =
        jsonDecode(jsonEncode(targets[i].outbound)) as Map<String, dynamic>;
    outbound['tag'] = 'probe-out-$i';
    if (bindAddress?.isNotEmpty == true) outbound['sendThrough'] = bindAddress;
    if (interfaceName?.isNotEmpty == true) {
      final stream =
          (outbound['streamSettings'] ??= <String, dynamic>{}) as Map;
      stream['sockopt'] = {'interface': interfaceName};
    }
    inbounds.add({
      'tag': 'probe-in-$i',
      'listen': '127.0.0.1',
      'port': ports[i],
      'protocol': 'http',
      'settings': <String, dynamic>{},
    });
    outbounds.add(outbound);
    rules.add({
      'type': 'field',
      'inboundTag': ['probe-in-$i'],
      'outboundTag': 'probe-out-$i',
    });
  }
  outbounds.add({'tag': 'probe-drop', 'protocol': 'blackhole'});
  rules.add({
    'type': 'field',
    'network': 'tcp,udp',
    'outboundTag': 'probe-drop',
  });
  return jsonEncode({
    'log': {'loglevel': 'none', 'access': 'none'},
    'inbounds': inbounds,
    'outbounds': outbounds,
    'routing': {'domainStrategy': 'AsIs', 'rules': rules},
  });
}

/// Checks every server with the bundled Xray in a private, short-lived process.
/// It never creates a TUN, changes routes or touches the running connection.
class WindowsProfileCheckBackend extends ProfileCheckBackend {
  WindowsProfileCheckBackend({
    Future<String?> Function()? resolveXray,
    Future<WindowsRouteUplink?> Function()? discoverUplink,
  }) : _resolveXray = resolveXray ?? VpnCoreBinaryManager().resolveExecutable,
       _discoverUplink =
           discoverUplink ??
           const MethodChannelWindowsRouteNativeApi().discoverPrimaryUplink;

  final Future<String?> Function() _resolveXray;
  final Future<WindowsRouteUplink?> Function() _discoverUplink;
  final Set<HttpClient> _clients = {};
  final Set<Process> _processes = {};
  bool _cancelled = false;

  @override
  Future<ProfileProbeRunResult> run(
    List<ProfileProbeTarget> targets,
    void Function(ProfileProbeTargetResult result) onResult,
  ) async {
    _cancelled = false;
    if (targets.isEmpty) return const ProfileProbeRunResult();
    final xray = await _resolveXray();
    if (xray == null) return const ProfileProbeRunResult(code: 'ENGINE_ERROR');
    final uplink = await _discoverUplink();
    if (uplink == null) return const ProfileProbeRunResult(code: 'NO_NETWORK');
    final dir = await Directory.systemTemp.createTemp('neura_probe_');
    try {
      final batch = await _start(xray, dir, targets, uplink);
      if (batch != null) {
        await _probeAll(
          targets,
          batch,
          onResult,
        ).timeout(_batchLimit, onTimeout: () {});
      } else {
        // One server the core rejects must not hide the others: retry alone.
        for (final target in targets) {
          if (_cancelled) break;
          final single = await _start(xray, dir, [target], uplink);
          final result = single == null
              ? ProfileProbeTargetResult(
                  target.id,
                  ProfileAvailability.error,
                  code: 'ENGINE_ERROR',
                )
              : await _probe(target.id, single.ports.first);
          single?.process.kill();
          if (!_cancelled) onResult(result);
        }
      }
      if (_cancelled) return const ProfileProbeRunResult(cancelled: true);
      final after = await _discoverUplink();
      if (after?.interfaceName != uplink.interfaceName) {
        return const ProfileProbeRunResult(code: 'NETWORK_CHANGED');
      }
      return const ProfileProbeRunResult();
    } catch (_) {
      // Never forward raw core output: it can contain credentials.
      return ProfileProbeRunResult(
        cancelled: _cancelled,
        code: _cancelled ? null : 'ENGINE_ERROR',
      );
    } finally {
      for (final process in _processes.toList()) {
        process.kill();
      }
      _processes.clear();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<_Batch?> _start(
    String xray,
    Directory dir,
    List<ProfileProbeTarget> targets,
    WindowsRouteUplink uplink,
  ) async {
    final ports = await _freePorts(targets.length);
    final file = File('${dir.path}${Platform.pathSeparator}probe.json');
    await file.writeAsString(
      buildWindowsProbeConfig(
        targets,
        ports,
        interfaceName: uplink.interfaceName,
        bindAddress: uplink.localAddress,
      ),
      flush: true,
    );
    final process = await Process.start(xray, ['run', '-c', file.path]);
    _processes.add(process);
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!exited && DateTime.now().isBefore(deadline)) {
      if (await _listening(ports.last)) return _Batch(process, ports);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    process.kill();
    _processes.remove(process);
    return null;
  }

  Future<void> _probeAll(
    List<ProfileProbeTarget> targets,
    _Batch batch,
    void Function(ProfileProbeTargetResult result) onResult,
  ) async {
    var next = 0;
    Future<void> worker() async {
      while (!_cancelled && next < targets.length) {
        final index = next++;
        final result = await _probe(targets[index].id, batch.ports[index]);
        if (!_cancelled) onResult(result);
      }
    }

    await Future.wait([
      for (var i = 0; i < _parallel && i < targets.length; i++) worker(),
    ]);
  }

  /// Real HTTPS through one server; the system trust store stays in force.
  Future<ProfileProbeTargetResult> _probe(String id, int port) async {
    var code = 'HTTPS_FAILED';
    for (final endpoint in _endpoints) {
      if (_cancelled) {
        return ProfileProbeTargetResult(id, ProfileAvailability.unknown);
      }
      final client = HttpClient()
        ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
        ..connectionTimeout = _timeout
        ..idleTimeout = Duration.zero;
      _clients.add(client);
      final watch = Stopwatch()..start();
      try {
        final request = await client
            .getUrl(Uri.parse(endpoint))
            .timeout(_timeout);
        request
          ..followRedirects = false
          ..persistentConnection = false;
        final response = await request.close().timeout(_timeout);
        await response.drain<void>().timeout(_timeout);
        if (response.statusCode == 204) {
          return ProfileProbeTargetResult(
            id,
            ProfileAvailability.available,
            code: 'HTTPS_OK',
            elapsedMs: watch.elapsedMilliseconds,
          );
        }
        code = 'HTTP_RESPONSE';
      } on TimeoutException {
        // A server too slow for one endpoint is too slow; do not double the wait.
        code = 'TIMEOUT';
        break;
      } catch (_) {
        code = 'HTTPS_FAILED';
      } finally {
        _clients.remove(client);
        client.close(force: true);
      }
    }
    return ProfileProbeTargetResult(
      id,
      _cancelled
          ? ProfileAvailability.unknown
          : ProfileAvailability.unavailable,
      code: code,
    );
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    for (final process in _processes.toList()) {
      process.kill();
    }
  }

  static Future<bool> _listening(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 200),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Holds every socket open until all are allocated so no port repeats.
  static Future<List<int>> _freePorts(int count) async {
    final sockets = <ServerSocket>[];
    try {
      for (var i = 0; i < count; i++) {
        sockets.add(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
      }
      return [for (final socket in sockets) socket.port];
    } finally {
      for (final socket in sockets) {
        await socket.close();
      }
    }
  }
}

class _Batch {
  _Batch(this.process, this.ports);
  final Process process;
  final List<int> ports;
}
