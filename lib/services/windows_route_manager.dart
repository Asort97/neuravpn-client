import 'dart:convert';
import 'dart:io';

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

class WindowsRouteManager {
  WindowsRouteManager({
    WindowsRouteProcessRunner? processRunner,
    bool? isWindowsOverride,
  }) : _processRunner = processRunner ?? _defaultProcessRunner,
       _isWindowsOverride = isWindowsOverride;

  final WindowsRouteProcessRunner _processRunner;
  final bool? _isWindowsOverride;

  bool get _isWindows => _isWindowsOverride ?? Platform.isWindows;

  Future<WindowsRouteUplink?> discoverPrimaryUplink({
    List<String>? logs,
  }) async {
    if (!_isWindows) return null;
    final sink = logs ?? <String>[];
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
    await cleanupStale(logs: logs);

    final tun = await _findTunInterface(preferredTunInterface, logs);
    if (tun == null) {
      return WindowsRouteApplyResult(
        success: false,
        error: 'Не удалось найти активный TUN интерфейс xray',
        logs: logs,
      );
    }

    final hintedTunAddress = _normalizeTunAddressHint(tunAddressHint);
    if (hintedTunAddress != null) {
      logs.add('Using provided TUN IPv4 address: $hintedTunAddress');
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

    final selectedUplink = uplink ?? await _findPrimaryDefaultRoute(logs);
    if (selectedUplink == null) {
      return WindowsRouteApplyResult(
        success: false,
        error: 'Не удалось определить основной uplink маршрут Windows',
        logs: logs,
      );
    }

    final protectedPrefixes = await _resolveProtectedPrefixes(
      remoteHost: remoteHost,
      dnsServers: dnsServers,
      logs: logs,
    );

    final applyOk = await _applyRouteBatch(
      protectedPrefixes: protectedPrefixes,
      uplinkInterfaceIndex: selectedUplink.interfaceIndex,
      uplinkGateway: selectedUplink.gateway,
      tunInterfaceIndex: tun.interfaceIndex,
      tunAddress: tunAddress,
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

  Future<void> cleanupSession(
    WindowsRouteSession? session, {
    List<String>? logs,
  }) async {
    if (!_isWindows || session == null) {
      return;
    }
    final sink = logs ?? <String>[];
    await _cleanupSessionBatch(session, sink);
  }

  Future<void> cleanupStale({List<String>? logs}) async {
    if (!_isWindows) return;
    final sink = logs ?? <String>[];
    await _cleanupStaleBatch(sink);
  }

  Future<_TunInterface?> _findTunInterface(
    String preferredTunInterface,
    List<String> logs,
  ) async {
    final escapedPreferred = _escapePs(preferredTunInterface);
    final result = await _runPowerShell(
      '''
\$preferred = '$escapedPreferred'
\$items = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
Where-Object { \$_.Name -eq \$preferred -or \$_.Name -eq 'xray0' -or \$_.Name -like 'xray*' -or \$_.Name -like 'tun-in*' -or \$_.Name -like 'wintun*' } |
Select-Object Name, InterfaceIndex
if (-not \$items) { exit 0 }
\$selected = \$items | Sort-Object @{ Expression = { if (\$_.Name -eq \$preferred) { 0 } elseif (\$_.Name -eq 'xray0') { 1 } elseif (\$_.Name -like 'xray*') { 2 } else { 3 } } } | Select-Object -First 1
\$selected | ConvertTo-Json -Compress
''',
      logs,
    );
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
    final result = await _runPowerShell(
      '''
\$items = Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
Where-Object { \$_.IPAddress -and \$_.IPAddress -ne '0.0.0.0' } |
Sort-Object @{ Expression = { if (\$_.IPAddress -like '169.254.*') { 1 } else { 0 } } }
if (-not \$items) { exit 0 }
(\$items | Select-Object -First 1 -ExpandProperty IPAddress) | ConvertTo-Json -Compress
''',
      logs,
    );
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

  Future<WindowsRouteUplink?> _findPrimaryDefaultRoute(List<String> logs) async {
    final result = await _runPowerShell(
      r'''
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
''',
      logs,
    );
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

  Future<List<String>> _resolveProtectedPrefixes({
    required String remoteHost,
    required List<String> dnsServers,
    required List<String> logs,
  }) async {
    final prefixes = <String>{};
    if (_looksLikeIpv4(remoteHost)) {
      prefixes.add(remoteHost);
    } else {
      try {
        final resolved = await InternetAddress.lookup(remoteHost);
        for (final address in resolved) {
          if (address.type == InternetAddressType.IPv4) {
            prefixes.add(address.address);
          }
        }
      } catch (e) {
        logs.add('Remote host resolve failed for $remoteHost: $e');
      }
    }
    for (final server in dnsServers) {
      final trimmed = server.trim();
      if (_looksLikeIpv4(trimmed)) {
        prefixes.add(trimmed);
      }
    }
    final result = prefixes.toList()..sort();
    logs.add('Protected host routes: ${result.join(', ')}');
    return result;
  }

  Future<bool> _applyRouteBatch({
    required List<String> protectedPrefixes,
    required int uplinkInterfaceIndex,
    required String uplinkGateway,
    required int tunInterfaceIndex,
    required String tunAddress,
    required List<String> logs,
  }) async {
    final protectedJson = jsonEncode(protectedPrefixes);
    final result = await _runPowerShell(
      '''
\$protected = ConvertFrom-Json @'
$protectedJson
'@
\$uplinkGateway = '${_escapePs(uplinkGateway)}'
\$tunAddress = '${_escapePs(tunAddress)}'
foreach (\$prefix in \$protected) {
  Get-NetRoute -DestinationPrefix "\$prefix/32" -InterfaceIndex $uplinkInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { \$_.NextHop -eq \$uplinkGateway } |
    Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
  New-NetRoute -DestinationPrefix "\$prefix/32" -InterfaceIndex $uplinkInterfaceIndex -NextHop \$uplinkGateway -RouteMetric 1 -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
}
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $tunInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
Get-NetRoute -DestinationPrefix '0.0.0.0/1' -InterfaceIndex $tunInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
Get-NetRoute -DestinationPrefix '128.0.0.0/1' -InterfaceIndex $tunInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
New-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $tunInterfaceIndex -NextHop \$tunAddress -RouteMetric 3 -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
''',
      logs,
    );
    return result.exitCode == 0;
  }

  Future<void> _cleanupSessionBatch(
    WindowsRouteSession session,
    List<String> logs,
  ) async {
    final protectedJson = jsonEncode(session.protectedPrefixes);
    await _runPowerShell(
      '''
\$protected = ConvertFrom-Json @'
$protectedJson
'@
\$uplinkGateway = '${_escapePs(session.uplinkGateway)}'
\$tunAddress = '${_escapePs(session.tunAddress)}'
foreach (\$prefix in \$protected) {
  Get-NetRoute -DestinationPrefix "\$prefix/32" -InterfaceIndex ${session.uplinkInterfaceIndex} -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { \$_.NextHop -eq \$uplinkGateway } |
    Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
}
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex ${session.tunInterfaceIndex} -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { \$_.NextHop -eq \$tunAddress } |
  Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
Get-NetRoute -DestinationPrefix '0.0.0.0/1' -InterfaceIndex ${session.tunInterfaceIndex} -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
Get-NetRoute -DestinationPrefix '128.0.0.0/1' -InterfaceIndex ${session.tunInterfaceIndex} -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Remove-NetRoute -Confirm:\$false -ErrorAction SilentlyContinue
''',
      logs,
      tolerateFailure: true,
    );
  }

  Future<void> _cleanupStaleBatch(List<String> logs) async {
    await _runPowerShell(
      r'''
$ifaces = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
Where-Object { $_.Name -like 'xray*' -or $_.Name -like 'tun-in*' -or $_.Name -like 'wintun*' }
foreach ($iface in $ifaces) {
  Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $($iface.InterfaceIndex) -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  Get-NetRoute -DestinationPrefix '0.0.0.0/1' -InterfaceIndex $($iface.InterfaceIndex) -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  Get-NetRoute -DestinationPrefix '128.0.0.0/1' -InterfaceIndex $($iface.InterfaceIndex) -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
}
''',
      logs,
      tolerateFailure: true,
    );
  }

  Future<ProcessResult> _run(
    String executable,
    List<String> arguments,
    List<String> logs, {
    bool tolerateFailure = false,
  }) async {
    try {
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
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
      logs,
      tolerateFailure: tolerateFailure,
    );
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
