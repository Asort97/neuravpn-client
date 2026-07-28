import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

typedef WindowsRouteProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class WindowsRouteUplink {
  const WindowsRouteUplink({
    required this.interfaceName,
    required this.interfaceIndex,
    required this.gateway,
    required this.localAddress,
  });

  final String interfaceName;
  final int interfaceIndex;
  final String gateway;
  final String localAddress;
}

class WindowsRouteSession {
  const WindowsRouteSession({
    required this.tunInterfaceName,
    required this.tunInterfaceIndex,
    required this.tunAddress,
    required this.uplinkInterfaceName,
    required this.uplinkInterfaceIndex,
    required this.uplinkGateway,
    required this.uplinkAddress,
    required this.protectedPrefixes,
  });

  final String tunInterfaceName;
  final int tunInterfaceIndex;
  final String tunAddress;
  final String uplinkInterfaceName;
  final int uplinkInterfaceIndex;
  final String uplinkGateway;
  final String uplinkAddress;
  final List<String> protectedPrefixes;
}

class WindowsRouteApplyResult {
  const WindowsRouteApplyResult({
    required this.success,
    this.session,
    this.error,
    this.logs = const <String>[],
  });

  final bool success;
  final WindowsRouteSession? session;
  final String? error;
  final List<String> logs;
}

class WindowsRouteNativeApplyResult {
  const WindowsRouteNativeApplyResult({
    required this.supported,
    this.session,
    this.error,
  });

  const WindowsRouteNativeApplyResult.unsupported()
    : supported = false,
      session = null,
      error = null;

  final bool supported;
  final WindowsRouteSession? session;
  final String? error;
}

abstract class WindowsRouteNativeApi {
  Future<WindowsRouteUplink?> discoverPrimaryUplink();

  Future<WindowsRouteNativeApplyResult> applyRoutes({
    required String preferredTunInterface,
    required String tunAddress,
    required int tunPrefixLength,
    required WindowsRouteUplink uplink,
    required List<String> protectedPrefixes,
  });
}

class MethodChannelWindowsRouteNativeApi implements WindowsRouteNativeApi {
  static const MethodChannel _channel = MethodChannel(
    'happycat.vpn/windows_route',
  );

  const MethodChannelWindowsRouteNativeApi();

  @override
  Future<WindowsRouteUplink?> discoverPrimaryUplink() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('discoverPrimaryUplink');
      final map = _asMap(raw);
      if (map == null || !_isSuccess(map)) {
        return null;
      }
      return _uplinkFromMap(map);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<WindowsRouteNativeApplyResult> applyRoutes({
    required String preferredTunInterface,
    required String tunAddress,
    required int tunPrefixLength,
    required WindowsRouteUplink uplink,
    required List<String> protectedPrefixes,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Object?>('applyRoutes', {
        'preferredTunInterface': preferredTunInterface,
        'tunAddress': tunAddress,
        'tunPrefixLength': tunPrefixLength,
        'uplinkInterfaceIndex': uplink.interfaceIndex,
        'uplinkGateway': uplink.gateway,
        'protectedPrefixes': protectedPrefixes,
      });
      final map = _asMap(raw);
      if (map == null) {
        return const WindowsRouteNativeApplyResult.unsupported();
      }
      if (!_isSuccess(map)) {
        return WindowsRouteNativeApplyResult(
          supported: true,
          error: _stringValue(map, 'error'),
        );
      }
      final tunName = _stringValue(map, 'tunInterfaceName');
      final tunAddressResult = _stringValue(map, 'tunAddress');
      final tunIndex = _intValue(map, 'tunInterfaceIndex');
      if (tunName == null ||
          tunName.isEmpty ||
          tunAddressResult == null ||
          tunAddressResult.isEmpty ||
          tunIndex == null) {
        return const WindowsRouteNativeApplyResult(
          supported: true,
          error: 'native_route_parse_failed',
        );
      }
      return WindowsRouteNativeApplyResult(
        supported: true,
        session: WindowsRouteSession(
          tunInterfaceName: tunName,
          tunInterfaceIndex: tunIndex,
          tunAddress: tunAddressResult,
          uplinkInterfaceName: uplink.interfaceName,
          uplinkInterfaceIndex: uplink.interfaceIndex,
          uplinkGateway: uplink.gateway,
          uplinkAddress: uplink.localAddress,
          protectedPrefixes: protectedPrefixes,
        ),
      );
    } on MissingPluginException {
      return const WindowsRouteNativeApplyResult.unsupported();
    } on PlatformException catch (e) {
      return WindowsRouteNativeApplyResult(
        supported: true,
        error: e.message ?? e.code,
      );
    }
  }

  static Map<Object?, Object?>? _asMap(Object? raw) {
    if (raw is Map<Object?, Object?>) {
      return raw;
    }
    if (raw is Map) {
      return raw.cast<Object?, Object?>();
    }
    return null;
  }

  static bool _isSuccess(Map<Object?, Object?> map) {
    final raw = map['success'];
    return raw == true || raw?.toString().toLowerCase() == 'true';
  }

  static WindowsRouteUplink? _uplinkFromMap(Map<Object?, Object?> map) {
    final interfaceName = _stringValue(map, 'interfaceName');
    final interfaceIndex = _intValue(map, 'interfaceIndex');
    final gateway = _stringValue(map, 'gateway');
    final localAddress = _stringValue(map, 'localAddress');
    if (interfaceName == null ||
        interfaceName.isEmpty ||
        interfaceIndex == null ||
        gateway == null ||
        gateway.isEmpty ||
        localAddress == null ||
        localAddress.isEmpty) {
      return null;
    }
    return WindowsRouteUplink(
      interfaceName: interfaceName,
      interfaceIndex: interfaceIndex,
      gateway: gateway,
      localAddress: localAddress,
    );
  }

  static String? _stringValue(Map<Object?, Object?> map, String key) {
    final raw = map[key];
    return raw?.toString();
  }

  static int? _intValue(Map<Object?, Object?> map, String key) {
    final raw = map[key];
    if (raw is int) {
      return raw;
    }
    return int.tryParse('${raw ?? ''}');
  }
}

class WindowsRouteManager {
  // Route metrics identify entries that this client owns. They must remain
  // low enough to win over the physical default route; ownership is scoped by
  // interface, next hop and metric during cleanup.
  static const int _protectedRouteMetric = 4;
  static const int _tunDefaultRouteMetric = 5;

  WindowsRouteManager({
    WindowsRouteProcessRunner? processRunner,
    bool? isWindowsOverride,
    void Function(String category)? processLaunchRecorder,
    WindowsRouteNativeApi? nativeApi,
    bool useNativeRouteApi = false,
  }) : _processRunner = processRunner ?? _defaultProcessRunner,
       _isWindowsOverride = isWindowsOverride,
       _processLaunchRecorder = processLaunchRecorder,
       _nativeApi = nativeApi ?? const MethodChannelWindowsRouteNativeApi(),
       _useNativeRouteApi = useNativeRouteApi;

  final WindowsRouteProcessRunner _processRunner;
  final bool? _isWindowsOverride;
  final void Function(String category)? _processLaunchRecorder;
  final WindowsRouteNativeApi _nativeApi;
  final bool _useNativeRouteApi;

  bool get _isWindows => _isWindowsOverride ?? Platform.isWindows;

  Future<WindowsRouteUplink?> discoverPrimaryUplink({
    List<String>? logs,
  }) async {
    if (!_isWindows) return null;
    final sink = logs ?? <String>[];
    if (_useNativeRouteApi) {
      final native = await _nativeApi.discoverPrimaryUplink();
      if (native != null) {
        sink.add(
          'Selected uplink route (native): ${native.interfaceName} via '
          '${native.gateway} (ifIndex=${native.interfaceIndex}, '
          'ip=${native.localAddress})',
        );
        return native;
      }
    }
    return _findPrimaryDefaultRoute(sink);
  }

  Future<WindowsRouteApplyResult> applyRoutes({
    required String preferredTunInterface,
    required String remoteHost,
    required List<String> dnsServers,
    String? tunAddressHint,
    WindowsRouteUplink? uplink,
  }) async {
    if (!_isWindows) {
      return const WindowsRouteApplyResult(success: true);
    }

    final logs = <String>[];

    final hintedTunAddress = _normalizeTunAddressHint(tunAddressHint);
    final hintedTunPrefixLength = _parseTunPrefixLength(tunAddressHint) ?? 30;
    if (hintedTunAddress != null) {
      logs.add(
        'Using provided TUN IPv4 address: '
        '$hintedTunAddress/$hintedTunPrefixLength',
      );
    }

    final selectedUplink = uplink ?? await _findPrimaryDefaultRoute(logs);
    if (selectedUplink == null) {
      return WindowsRouteApplyResult(
        success: false,
        error: 'Не удалось определить основной uplink маршрут Windows',
        logs: logs,
      );
    }

    final protected = await _resolveProtectedPrefixes(
      remoteHost: remoteHost,
      dnsServers: dnsServers,
      logs: logs,
    );
    if (protected.remotePrefixes.isEmpty) {
      return WindowsRouteApplyResult(
        success: false,
        error:
            'Не удалось определить IPv4 адрес VPN-сервера; маршруты не менялись',
        logs: logs,
      );
    }
    final protectedPrefixes = protected.allPrefixes;

    if (_useNativeRouteApi) {
      final nativeBatch = await _applyRouteBatchNative(
        preferredTunInterface: preferredTunInterface,
        tunAddress: hintedTunAddress,
        tunPrefixLength: hintedTunPrefixLength,
        uplink: selectedUplink,
        protectedPrefixes: protectedPrefixes,
        logs: logs,
      );
      if (nativeBatch.session != null) {
        return WindowsRouteApplyResult(
          success: true,
          session: nativeBatch.session,
          logs: logs,
        );
      }
    }

    final fastBatch = await _applyRouteBatchFast(
      preferredTunInterface: preferredTunInterface,
      tunAddressHint: hintedTunAddress,
      tunPrefixLength: hintedTunPrefixLength,
      uplink: selectedUplink,
      protectedPrefixes: protectedPrefixes,
      logs: logs,
    );
    if (fastBatch.session != null) {
      return WindowsRouteApplyResult(
        success: true,
        session: fastBatch.session,
        logs: logs,
      );
    }
    if (!fastBatch.canFallback) {
      return WindowsRouteApplyResult(
        success: false,
        error:
            fastBatch.error ?? 'Не удалось направить default route через TUN',
        logs: logs,
      );
    }

    logs.add('Fast route setup failed; falling back to legacy route pipeline.');
    return _applyRoutesLegacy(
      preferredTunInterface: preferredTunInterface,
      hintedTunAddress: hintedTunAddress,
      hintedTunPrefixLength: hintedTunPrefixLength,
      selectedUplink: selectedUplink,
      protectedPrefixes: protectedPrefixes,
      logs: logs,
    );
  }

  Future<WindowsRouteApplyResult> _applyRoutesLegacy({
    required String preferredTunInterface,
    required String? hintedTunAddress,
    required int hintedTunPrefixLength,
    required WindowsRouteUplink selectedUplink,
    required List<String> protectedPrefixes,
    required List<String> logs,
  }) async {
    final tun = await _findTunInterface(preferredTunInterface, logs);
    if (tun == null) {
      return WindowsRouteApplyResult(
        success: false,
        error: 'Не удалось найти активный TUN интерфейс xray',
        logs: logs,
      );
    }

    final tunAddress =
        hintedTunAddress ?? await _findTunAddress(tun.interfaceIndex, logs);
    if (tunAddress == null) {
      return WindowsRouteApplyResult(
        success: false,
        error: 'Не удалось определить IPv4 адрес TUN интерфейса ${tun.name}',
        logs: logs,
      );
    }

    final applyOk = await _applyRouteBatch(
      protectedPrefixes: protectedPrefixes,
      uplinkInterfaceIndex: selectedUplink.interfaceIndex,
      uplinkGateway: selectedUplink.gateway,
      tunInterfaceIndex: tun.interfaceIndex,
      tunAddress: tunAddress,
      tunPrefixLength: hintedTunPrefixLength,
      logs: logs,
    );
    if (!applyOk) {
      return WindowsRouteApplyResult(
        success: false,
        error: 'Не удалось направить default route через ${tun.name}',
        logs: logs,
      );
    }

    return WindowsRouteApplyResult(
      success: true,
      session: WindowsRouteSession(
        tunInterfaceName: tun.name,
        tunInterfaceIndex: tun.interfaceIndex,
        tunAddress: tunAddress,
        uplinkInterfaceName: selectedUplink.interfaceName,
        uplinkInterfaceIndex: selectedUplink.interfaceIndex,
        uplinkGateway: selectedUplink.gateway,
        uplinkAddress: selectedUplink.localAddress,
        protectedPrefixes: protectedPrefixes,
      ),
      logs: logs,
    );
  }

  Future<WindowsRouteNativeApplyResult> _applyRouteBatchNative({
    required String preferredTunInterface,
    required String? tunAddress,
    required int tunPrefixLength,
    required WindowsRouteUplink uplink,
    required List<String> protectedPrefixes,
    required List<String> logs,
  }) async {
    if (tunAddress == null) {
      return const WindowsRouteNativeApplyResult.unsupported();
    }
    final result = await _nativeApi.applyRoutes(
      preferredTunInterface: preferredTunInterface,
      tunAddress: tunAddress,
      tunPrefixLength: tunPrefixLength,
      uplink: uplink,
      protectedPrefixes: protectedPrefixes,
    );
    if (result.session != null) {
      logs.add(
        'Route batch applied natively through '
        '${result.session!.tunInterfaceName}',
      );
      return result;
    }
    if (result.supported && result.error != null) {
      logs.add('Native route setup failed: ${result.error}');
    }
    return result;
  }

  Future<void> cleanupSession(
    WindowsRouteSession? session, {
    List<String>? logs,
  }) async {
    if (!_isWindows || session == null) {
      return;
    }
    final sink = logs ?? <String>[];
    for (var attempt = 1; attempt <= 2; attempt++) {
      final applied = await _cleanupSessionBatch(session, sink);
      final clean = await _verifySessionCleanup(session, sink);
      if (applied && clean) {
        return;
      }
      sink.add('Route cleanup verification failed on attempt $attempt/2.');
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  Future<bool> cleanupStale({
    String? ownedInterfaceName,
    List<String>? logs,
  }) async {
    if (!_isWindows) return true;
    final sink = logs ?? <String>[];
    final normalizedName = ownedInterfaceName?.trim();
    if (normalizedName == null || normalizedName.isEmpty) {
      sink.add('Skipping stale-route cleanup without an owned interface name.');
      return false;
    }
    return _cleanupStaleBatch(normalizedName, sink);
  }

  Future<_TunInterface?> _findTunInterface(
    String preferredTunInterface,
    List<String> logs,
  ) async {
    final escapedPreferred = _escapePs(preferredTunInterface);
    final result = await _runPowerShell('''
\$preferred = '$escapedPreferred'
\$items = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
Where-Object { \$_.Name -eq \$preferred -or \$_.Name -eq 'xray0' -or \$_.Name -like 'xray*' -or \$_.Name -like 'tun-in*' -or \$_.Name -like 'wintun*' } |
Select-Object Name, InterfaceIndex
if (-not \$items) { exit 0 }
\$selected = \$items | Sort-Object @{ Expression = { if (\$_.Name -eq \$preferred) { 0 } elseif (\$_.Name -eq 'xray0') { 1 } elseif (\$_.Name -like 'xray*') { 2 } else { 3 } } } | Select-Object -First 1
\$selected | ConvertTo-Json -Compress
''', logs);
    if (result.exitCode != 0) return null;
    final parsed = _decodeJson(result.stdout);
    if (parsed is! Map) return null;
    final name = parsed['Name']?.toString();
    final index = int.tryParse('${parsed['InterfaceIndex'] ?? ''}');
    if (name == null || name.isEmpty || index == null) return null;
    logs.add('Selected TUN interface: $name (ifIndex=$index)');
    return _TunInterface(name: name, interfaceIndex: index);
  }

  Future<String?> _findTunAddress(int interfaceIndex, List<String> logs) async {
    final result = await _runPowerShell('''
\$items = Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
Where-Object { \$_.IPAddress -and \$_.IPAddress -ne '0.0.0.0' } |
Sort-Object @{ Expression = { if (\$_.IPAddress -like '169.254.*') { 1 } else { 0 } } }
if (-not \$items) { exit 0 }
(\$items | Select-Object -First 1 -ExpandProperty IPAddress) | ConvertTo-Json -Compress
''', logs);
    if (result.exitCode != 0) return null;
    final parsed = _decodeJson(result.stdout);
    final address = parsed?.toString().trim();
    if (address == null || address.isEmpty) return null;
    logs.add('Selected TUN IPv4 address: $address');
    return address;
  }

  String? _normalizeTunAddressHint(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final address = trimmed.split('/').first.trim();
    return _looksLikeIpv4(address) ? address : null;
  }

  int? _parseTunPrefixLength(String? value) {
    if (value == null) return null;
    final parts = value.trim().split('/');
    if (parts.length < 2) return null;
    final prefix = int.tryParse(parts[1].trim());
    if (prefix == null || prefix < 1 || prefix > 32) return null;
    return prefix;
  }

  Future<WindowsRouteUplink?> _findPrimaryDefaultRoute(
    List<String> logs,
  ) async {
    final result = await _runPowerShell(r'''
$routes =
  Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
  Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' -and $_.InterfaceAlias -notlike 'Loopback*' } |
  ForEach-Object {
    $iface = Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
    $ip = Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -and $_.IPAddress -ne '0.0.0.0' -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike '127.*' } |
      Sort-Object SkipAsSource, @{ Expression = { -$_.PrefixLength } } |
      Select-Object -First 1 -ExpandProperty IPAddress
    [pscustomobject]@{
      InterfaceIndex = $_.InterfaceIndex
      InterfaceAlias = $_.InterfaceAlias
      NextHop = $_.NextHop
      LocalAddress = $ip
      RouteMetric = $_.RouteMetric
      InterfaceMetric = if ($iface) { $iface.InterfaceMetric } else { 9999 }
    }
  } |
  Sort-Object RouteMetric, InterfaceMetric
$routes | Select-Object -First 1 | ConvertTo-Json -Compress
''', logs);
    if (result.exitCode != 0) return null;
    final parsed = _decodeJson(result.stdout);
    if (parsed is! Map) return null;
    final alias = parsed['InterfaceAlias']?.toString();
    final gateway = parsed['NextHop']?.toString();
    final localAddress = parsed['LocalAddress']?.toString();
    final index = int.tryParse('${parsed['InterfaceIndex'] ?? ''}');
    if (alias == null ||
        alias.isEmpty ||
        gateway == null ||
        gateway.isEmpty ||
        localAddress == null ||
        localAddress.isEmpty ||
        index == null) {
      return null;
    }
    logs.add(
      'Selected uplink route: $alias via $gateway (ifIndex=$index, ip=$localAddress)',
    );
    return WindowsRouteUplink(
      interfaceName: alias,
      interfaceIndex: index,
      gateway: gateway,
      localAddress: localAddress,
    );
  }

  Future<_ProtectedPrefixes> _resolveProtectedPrefixes({
    required String remoteHost,
    required List<String> dnsServers,
    required List<String> logs,
  }) async {
    final remotePrefixes = <String>{};
    if (_looksLikeIpv4(remoteHost)) {
      remotePrefixes.add(remoteHost);
    } else {
      try {
        final resolved = await InternetAddress.lookup(
          remoteHost,
        ).timeout(const Duration(milliseconds: 900));
        for (final address in resolved) {
          if (address.type == InternetAddressType.IPv4) {
            remotePrefixes.add(address.address);
          }
        }
      } on TimeoutException {
        logs.add('Remote host resolve timed out for $remoteHost');
      } catch (e) {
        logs.add('Remote host resolve failed for $remoteHost: $e');
      }
    }
    final prefixes = <String>{...remotePrefixes};
    for (final server in dnsServers) {
      final trimmed = server.trim();
      if (_looksLikeIpv4(trimmed)) {
        prefixes.add(trimmed);
      }
    }
    final result = prefixes.toList()..sort();
    final resolvedRemote = remotePrefixes.toList()..sort();
    logs.add('Protected host routes: ${result.join(', ')}');
    return _ProtectedPrefixes(
      allPrefixes: result,
      remotePrefixes: resolvedRemote,
    );
  }

  Future<_RouteBatchResult> _applyRouteBatchFast({
    required String preferredTunInterface,
    required String? tunAddressHint,
    required int tunPrefixLength,
    required WindowsRouteUplink uplink,
    required List<String> protectedPrefixes,
    required List<String> logs,
  }) async {
    final protectedJson = jsonEncode(protectedPrefixes);
    final escapedPreferred = _escapePs(preferredTunInterface);
    final escapedTunAddress = _escapePs(tunAddressHint ?? '');
    final escapedUplinkGateway = _escapePs(uplink.gateway);
    final result = await _runPowerShell('''
\$preferred = '$escapedPreferred'
\$tunAddressHint = '$escapedTunAddress'
\$tunPrefixLength = $tunPrefixLength
\$uplinkGateway = '$escapedUplinkGateway'
\$protected = ConvertFrom-Json @'
$protectedJson
'@
try {
  \$items = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
    Where-Object { \$_.Name -eq \$preferred -or \$_.Name -eq 'xray0' -or \$_.Name -like 'xray*' -or \$_.Name -like 'tun-in*' -or \$_.Name -like 'wintun*' } |
    Select-Object Name, InterfaceIndex
  if (-not \$items) {
    [pscustomobject]@{ Success = \$false; Error = 'tun_not_found' } | ConvertTo-Json -Compress
    exit 0
  }
  \$selected = \$items |
    Sort-Object @{ Expression = { if (\$_.Name -eq \$preferred) { 0 } elseif (\$_.Name -eq 'xray0') { 1 } elseif (\$_.Name -like 'xray*') { 2 } else { 3 } } } |
    Select-Object -First 1
  \$tunAddress = \$tunAddressHint
  if (-not \$tunAddress) {
    \$tunAddress = Get-NetIPAddress -InterfaceIndex \$selected.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { \$_.IPAddress -and \$_.IPAddress -ne '0.0.0.0' } |
      Sort-Object @{ Expression = { if (\$_.IPAddress -like '169.254.*') { 1 } else { 0 } } } |
      Select-Object -First 1 -ExpandProperty IPAddress
  }
  if (-not \$tunAddress) {
    [pscustomobject]@{ Success = \$false; Error = 'tun_address_not_found'; TunName = \$selected.Name; TunInterfaceIndex = [int]\$selected.InterfaceIndex } | ConvertTo-Json -Compress
    exit 0
  }
  \$existingTunIp = Get-NetIPAddress -InterfaceIndex \$selected.InterfaceIndex -AddressFamily IPv4 -IPAddress \$tunAddress -ErrorAction SilentlyContinue
  if (-not \$existingTunIp) {
    Get-NetIPAddress -InterfaceIndex \$selected.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { \$_.IPAddress -like '169.254.*' } |
      Remove-NetIPAddress -Confirm:\$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex \$selected.InterfaceIndex -IPAddress \$tunAddress -PrefixLength \$tunPrefixLength -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
  }
  foreach (\$prefix in @(\$protected)) {
    if (-not \$prefix) { continue }
    Get-NetRoute -DestinationPrefix "\$prefix/32" -InterfaceIndex ${uplink.interfaceIndex} -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { \$_.NextHop -eq \$uplinkGateway -and \$_.RouteMetric -eq $_protectedRouteMetric } |
      Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
    New-NetRoute -DestinationPrefix "\$prefix/32" -InterfaceIndex ${uplink.interfaceIndex} -NextHop \$uplinkGateway -RouteMetric $_protectedRouteMetric -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
  }
  Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex \$selected.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { \$_.RouteMetric -eq $_tunDefaultRouteMetric } |
    Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
  New-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex \$selected.InterfaceIndex -NextHop '0.0.0.0' -RouteMetric $_tunDefaultRouteMetric -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
  [pscustomobject]@{
    Success = \$true
    TunName = \$selected.Name
    TunInterfaceIndex = [int]\$selected.InterfaceIndex
    TunAddress = \$tunAddress
  } | ConvertTo-Json -Compress
} catch {
  foreach (\$prefix in @(\$protected)) {
    Get-NetRoute -DestinationPrefix "\$prefix/32" -InterfaceIndex ${uplink.interfaceIndex} -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { \$_.NextHop -eq \$uplinkGateway -and \$_.RouteMetric -eq $_protectedRouteMetric } |
      Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
  }
  Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex \$selected.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { \$_.RouteMetric -eq $_tunDefaultRouteMetric } |
    Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
  [pscustomobject]@{ Success = \$false; Error = \$_.Exception.Message } | ConvertTo-Json -Compress
}
''', logs);
    if (result.exitCode != 0) {
      return _RouteBatchResult(error: 'route_batch_failed', canFallback: true);
    }

    final parsed = _decodeJson(result.stdout);
    if (parsed is! Map) {
      return _RouteBatchResult(
        error: 'route_batch_parse_failed',
        canFallback: true,
      );
    }
    final success =
        parsed['Success'] == true ||
        parsed['Success']?.toString().toLowerCase() == 'true';
    if (!success) {
      final error = parsed['Error']?.toString();
      logs.add('Fast route setup failed: ${error ?? 'unknown error'}');
      return _RouteBatchResult(
        error: _routeBatchErrorMessage(error),
        canFallback: false,
      );
    }

    final tunName = parsed['TunName']?.toString();
    final tunAddress = parsed['TunAddress']?.toString();
    final tunIndex = int.tryParse('${parsed['TunInterfaceIndex'] ?? ''}');
    if (tunName == null ||
        tunName.isEmpty ||
        tunAddress == null ||
        tunAddress.isEmpty ||
        tunIndex == null) {
      return _RouteBatchResult(
        error: 'route_batch_parse_failed',
        canFallback: true,
      );
    }

    logs.add('Selected TUN interface: $tunName (ifIndex=$tunIndex)');
    logs.add('Selected TUN IPv4 address: $tunAddress');
    logs.add('Route batch applied through $tunName');
    return _RouteBatchResult(
      session: WindowsRouteSession(
        tunInterfaceName: tunName,
        tunInterfaceIndex: tunIndex,
        tunAddress: tunAddress,
        uplinkInterfaceName: uplink.interfaceName,
        uplinkInterfaceIndex: uplink.interfaceIndex,
        uplinkGateway: uplink.gateway,
        uplinkAddress: uplink.localAddress,
        protectedPrefixes: protectedPrefixes,
      ),
    );
  }

  String _routeBatchErrorMessage(String? error) {
    switch (error) {
      case 'tun_not_found':
        return 'Не удалось найти активный TUN интерфейс xray';
      case 'tun_address_not_found':
        return 'Не удалось определить IPv4 адрес TUN интерфейса';
      case 'route_batch_parse_failed':
        return 'Не удалось прочитать результат настройки маршрутов Windows';
      default:
        if (error != null && error.isNotEmpty) {
          return 'Не удалось настроить маршруты Windows: $error';
        }
        return 'Не удалось настроить маршруты Windows';
    }
  }

  Future<bool> _applyRouteBatch({
    required List<String> protectedPrefixes,
    required int uplinkInterfaceIndex,
    required String uplinkGateway,
    required int tunInterfaceIndex,
    required String tunAddress,
    required int tunPrefixLength,
    required List<String> logs,
  }) async {
    final protectedJson = jsonEncode(protectedPrefixes);
    final result = await _runPowerShell('''
\$protected = ConvertFrom-Json @'
$protectedJson
'@
\$uplinkGateway = '${_escapePs(uplinkGateway)}'
\$tunAddress = '${_escapePs(tunAddress)}'
\$existingTunIp = Get-NetIPAddress -InterfaceIndex $tunInterfaceIndex -AddressFamily IPv4 -IPAddress \$tunAddress -ErrorAction SilentlyContinue
if (-not \$existingTunIp) {
  Get-NetIPAddress -InterfaceIndex $tunInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { \$_.IPAddress -like '169.254.*' } |
    Remove-NetIPAddress -Confirm:\$false -ErrorAction SilentlyContinue
  New-NetIPAddress -InterfaceIndex $tunInterfaceIndex -IPAddress \$tunAddress -PrefixLength $tunPrefixLength -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
}
foreach (\$prefix in \$protected) {
  Get-NetRoute -DestinationPrefix "\$prefix/32" -InterfaceIndex $uplinkInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { \$_.NextHop -eq \$uplinkGateway -and \$_.RouteMetric -eq $_protectedRouteMetric } |
    Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
  New-NetRoute -DestinationPrefix "\$prefix/32" -InterfaceIndex $uplinkInterfaceIndex -NextHop \$uplinkGateway -RouteMetric $_protectedRouteMetric -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
}
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $tunInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { \$_.RouteMetric -eq $_tunDefaultRouteMetric } |
  Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
New-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $tunInterfaceIndex -NextHop '0.0.0.0' -RouteMetric $_tunDefaultRouteMetric -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
''', logs);
    return result.exitCode == 0;
  }

  Future<bool> _cleanupSessionBatch(
    WindowsRouteSession session,
    List<String> logs,
  ) async {
    final protectedJson = jsonEncode(session.protectedPrefixes);
    final result = await _runPowerShell(
      '''
\$protected = ConvertFrom-Json @'
$protectedJson
'@
\$uplinkGateway = '${_escapePs(session.uplinkGateway)}'
\$tunAddress = '${_escapePs(session.tunAddress)}'
foreach (\$prefix in \$protected) {
  Get-NetRoute -DestinationPrefix "\$prefix/32" -InterfaceIndex ${session.uplinkInterfaceIndex} -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { \$_.NextHop -eq \$uplinkGateway -and \$_.RouteMetric -eq $_protectedRouteMetric } |
    Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
}
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex ${session.tunInterfaceIndex} -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { \$_.RouteMetric -eq $_tunDefaultRouteMetric } |
  Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
''',
      logs,
      tolerateFailure: true,
    );
    return result.exitCode == 0;
  }

  Future<bool> _verifySessionCleanup(
    WindowsRouteSession session,
    List<String> logs,
  ) async {
    final protectedJson = jsonEncode(session.protectedPrefixes);
    final result = await _runPowerShell(
      '''
\$protected = ConvertFrom-Json @'
$protectedJson
'@
\$remaining = @()
foreach (\$prefix in \$protected) {
  \$remaining += Get-NetRoute -DestinationPrefix "\$prefix/32" -InterfaceIndex ${session.uplinkInterfaceIndex} -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { \$_.NextHop -eq '${_escapePs(session.uplinkGateway)}' -and \$_.RouteMetric -eq $_protectedRouteMetric }
}
\$remaining += Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex ${session.tunInterfaceIndex} -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { \$_.RouteMetric -eq $_tunDefaultRouteMetric }
if (\$remaining.Count -eq 0) { exit 0 }
exit 1
''',
      logs,
      tolerateFailure: true,
    );
    return result.exitCode == 0;
  }

  Future<bool> _cleanupStaleBatch(
    String ownedInterfaceName,
    List<String> logs,
  ) async {
    final escapedName = _escapePs(ownedInterfaceName);
    final result = await _runPowerShell(
      '''
\$iface = Get-NetAdapter -Name '$escapedName' -IncludeHidden -ErrorAction SilentlyContinue
if (\$iface) {
  Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex \$iface.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { \$_.RouteMetric -eq $_tunDefaultRouteMetric } |
    Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
}
''',
      logs,
      tolerateFailure: true,
    );
    return result.exitCode == 0;
  }

  Future<ProcessResult> _run(
    String executable,
    List<String> arguments,
    List<String> logs, {
    bool tolerateFailure = false,
  }) async {
    try {
      _processLaunchRecorder?.call(_categorize(executable));
      final result = await _processRunner(executable, arguments);
      logs.add('$executable ${arguments.join(' ')} => ${result.exitCode}');
      final stderr = '${result.stderr}'.trim();
      if (stderr.isNotEmpty && (!tolerateFailure || result.exitCode != 0)) {
        logs.add(stderr);
      }
      return result;
    } catch (e) {
      logs.add('$executable ${arguments.join(' ')} threw: $e');
      return ProcessResult(-1, 1, '', '$e');
    }
  }

  Future<ProcessResult> _runPowerShell(
    String script,
    List<String> logs, {
    bool tolerateFailure = false,
  }) {
    return _run(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
      logs,
      tolerateFailure: tolerateFailure,
    );
  }

  String _categorize(String executable) {
    final normalized = executable.toLowerCase();
    if (normalized == 'powershell' || normalized.endsWith('\\powershell.exe')) {
      return 'powershell';
    }
    if (normalized == 'netsh' || normalized.endsWith('\\netsh.exe')) {
      return 'netsh';
    }
    return normalized;
  }

  dynamic _decodeJson(Object? raw) {
    final text = '${raw ?? ''}'.trim();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  String _escapePs(String value) => value.replaceAll("'", "''");

  bool _looksLikeIpv4(String value) {
    return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(value);
  }

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments);
  }
}

class _TunInterface {
  const _TunInterface({required this.name, required this.interfaceIndex});

  final String name;
  final int interfaceIndex;
}

class _RouteBatchResult {
  const _RouteBatchResult({this.session, this.error, this.canFallback = false});

  final WindowsRouteSession? session;
  final String? error;
  final bool canFallback;
}

class _ProtectedPrefixes {
  const _ProtectedPrefixes({
    required this.allPrefixes,
    required this.remotePrefixes,
  });

  final List<String> allPrefixes;
  final List<String> remotePrefixes;
}
