import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

typedef WindowsDnsProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class WindowsDnsResult {
  const WindowsDnsResult({
    required this.success,
    this.error,
    this.logs = const <String>[],
  });

  final bool success;
  final String? error;
  final List<String> logs;
}

class WindowsDnsTestResult extends WindowsDnsResult {
  const WindowsDnsTestResult({
    required super.success,
    super.error,
    super.logs,
    this.successfulQueries = 0,
    this.addresses = const <String>[],
    this.httpStatusCode,
  });

  final int successfulQueries;
  final List<String> addresses;
  final int? httpStatusCode;
}

/// Owns the Windows DNS changes made for a full-tunnel Xray session.
///
/// The original interface and DoH state is persisted before any mutation.
/// NRPT is intentionally not modified, so rules owned by Windows or other
/// VPN clients remain untouched.
class WindowsDnsManager {
  WindowsDnsManager({
    WindowsDnsProcessRunner? processRunner,
    bool? isWindowsOverride,
    File? backupFile,
  }) : _processRunner = processRunner ?? _defaultProcessRunner,
       _isWindowsOverride = isWindowsOverride,
       _backupFileOverride = backupFile;

  static const String managedRuleName = 'NeuraVPN Secure DNS';
  static const List<String> secureDnsServers = <String>[
    '9.9.9.9',
    '149.112.112.112',
  ];
  static const String dohTemplate = 'https://dns.quad9.net/dns-query';
  static const String defaultProbeUrl =
      'https://tr.rbxcdn.com/'
      '180DAY-24b227dfaa727ea3b643df52ab801d3a/'
      '384/216/Image/Webp/noFilter';

  final WindowsDnsProcessRunner _processRunner;
  final bool? _isWindowsOverride;
  final File? _backupFileOverride;

  bool get _isWindows => _isWindowsOverride ?? Platform.isWindows;

  Future<WindowsDnsResult> prepare({required int uplinkInterfaceIndex}) async {
    if (!_isWindows) {
      return const WindowsDnsResult(success: true);
    }
    final backup = _backupFile;
    if (await backup.exists()) {
      return const WindowsDnsResult(
        success: true,
        logs: <String>[
          '[dns] Existing NeuraVPN DNS backup retained for recovery.',
        ],
      );
    }

    final result = await _runPowerShell(
      _captureStateScript(uplinkInterfaceIndex),
    );
    if (result.exitCode != 0) {
      return WindowsDnsResult(success: false, error: _resultDetails(result));
    }
    final decoded = _decodeMap(result.stdout);
    if (decoded == null || decoded['Interfaces'] == null) {
      return const WindowsDnsResult(
        success: false,
        error: 'dns_backup_parse_failed',
      );
    }
    decoded['Version'] = 1;
    decoded['ManagedBy'] = managedRuleName;
    decoded['Phase'] = 'prepared';
    decoded['CreatedAt'] = DateTime.now().toUtc().toIso8601String();
    await backup.parent.create(recursive: true);
    await backup.writeAsString(jsonEncode(decoded), flush: true);
    return WindowsDnsResult(
      success: true,
      logs: <String>['[dns] Original Windows DNS state saved: ${backup.path}'],
    );
  }

  Future<WindowsDnsResult> apply({
    required int uplinkInterfaceIndex,
    required int tunInterfaceIndex,
  }) async {
    if (!_isWindows) {
      return const WindowsDnsResult(success: true);
    }
    final backup = _backupFile;
    if (!await backup.exists()) {
      final prepared = await prepare(
        uplinkInterfaceIndex: uplinkInterfaceIndex,
      );
      if (!prepared.success) return prepared;
    }

    final state = await _readBackup();
    if (state == null) {
      return const WindowsDnsResult(
        success: false,
        error: 'dns_backup_invalid',
      );
    }
    final interfaces = _asMapList(state['Interfaces']);
    if (!interfaces.any(
      (item) => _asInt(item['InterfaceIndex']) == tunInterfaceIndex,
    )) {
      final capture = await _runPowerShell(
        _captureInterfaceScript(tunInterfaceIndex),
      );
      if (capture.exitCode != 0) {
        return WindowsDnsResult(
          success: false,
          error: 'dns_tun_backup_failed: ${_resultDetails(capture)}',
        );
      }
      final tunState = _decodeMap(capture.stdout);
      if (tunState == null ||
          _asInt(tunState['InterfaceIndex']) != tunInterfaceIndex) {
        return const WindowsDnsResult(
          success: false,
          error: 'dns_tun_backup_parse_failed',
        );
      }
      interfaces.add(tunState);
      state['Interfaces'] = interfaces;
      state['Phase'] = 'applying';
      await backup.writeAsString(jsonEncode(state), flush: true);
    }

    final result = await _runPowerShell(_applyScript(<int>[tunInterfaceIndex]));
    final decoded = _decodeMap(result.stdout);
    final success =
        result.exitCode == 0 && decoded != null && decoded['Success'] == true;
    if (!success) {
      return WindowsDnsResult(
        success: false,
        error: decoded?['Error']?.toString() ?? _resultDetails(result),
        logs: const <String>['[dns] Secure DNS apply failed.'],
      );
    }
    state['Phase'] = 'applied';
    await backup.writeAsString(jsonEncode(state), flush: true);
    final addresses = _asStringList(decoded['Addresses']);
    return WindowsDnsResult(
      success: true,
      logs: <String>[
        '[dns] Quad9 DNS assigned to the TUN interface.',
        '[dns] Managed NRPT root rule directs system DNS through the tunnel.',
        '[dns] Windows DoH enabled without UDP fallback.',
        '[dns] Probe resolved tr.rbxcdn.com: ${addresses.join(', ')}',
      ],
    );
  }

  Future<WindowsDnsResult> restore() async {
    if (!_isWindows) {
      return const WindowsDnsResult(success: true);
    }
    final backup = _backupFile;
    if (!await backup.exists()) {
      return const WindowsDnsResult(success: true);
    }
    final state = await _readBackup();
    if (state == null || state['ManagedBy'] != managedRuleName) {
      return const WindowsDnsResult(
        success: false,
        error: 'dns_backup_invalid_or_foreign',
      );
    }

    final result = await _runPowerShell(_restoreScript(state));
    final decoded = _decodeMap(result.stdout);
    final success =
        result.exitCode == 0 && decoded != null && decoded['Success'] == true;
    if (!success) {
      return WindowsDnsResult(
        success: false,
        error: decoded?['Error']?.toString() ?? _resultDetails(result),
        logs: const <String>[
          '[dns] Original DNS restore failed; backup was retained.',
        ],
      );
    }
    await backup.delete();
    return const WindowsDnsResult(
      success: true,
      logs: <String>['[dns] Original interface DNS and DoH state restored.'],
    );
  }

  Future<WindowsDnsResult> recover() async {
    final result = await restore();
    if (!result.success || result.logs.isEmpty) return result;
    return WindowsDnsResult(
      success: true,
      logs: <String>[
        '[dns] Recovered unfinished NeuraVPN DNS session.',
        ...result.logs,
      ],
    );
  }

  Future<WindowsDnsTestResult> test({
    String domain = 'tr.rbxcdn.com',
    int attempts = 20,
    String probeUrl = defaultProbeUrl,
  }) async {
    if (!_isWindows) {
      return const WindowsDnsTestResult(success: true);
    }
    final safeDomain = domain.replaceAll("'", "''");
    final safeProbeUrl = probeUrl.replaceAll("'", "''");
    final safeAttempts = attempts.clamp(1, 100);
    final result = await _runPowerShell('''
\$success = 0
\$addresses = @()
\$lastError = \$null
\$httpStatusCode = \$null
for (\$i = 0; \$i -lt $safeAttempts; \$i++) {
  try {
    \$resolved = Resolve-DnsName -Name '$safeDomain' -Type A -DnsOnly -ErrorAction Stop |
      Where-Object { \$_.IPAddress } |
      Select-Object -ExpandProperty IPAddress
    if (@(\$resolved).Count -eq 0) { throw 'no_ipv4_records' }
    \$success++
    \$addresses += @(\$resolved)
  } catch {
    \$lastError = \$_.Exception.Message
  }
}
if (\$success -eq $safeAttempts) {
  try {
    \$response = Invoke-WebRequest -Uri '$safeProbeUrl' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    \$httpStatusCode = [int]\$response.StatusCode
  } catch {
    \$lastError = \$_.Exception.Message
    if (\$_.Exception.Response -and \$_.Exception.Response.StatusCode) {
      \$httpStatusCode = [int]\$_.Exception.Response.StatusCode
    }
  }
}
[pscustomobject]@{
  Success = (\$success -eq $safeAttempts -and \$httpStatusCode -eq 200)
  SuccessfulQueries = \$success
  Addresses = @(\$addresses | Sort-Object -Unique)
  HttpStatusCode = \$httpStatusCode
  Error = \$lastError
} | ConvertTo-Json -Compress
''');
    final decoded = _decodeMap(result.stdout);
    final successfulQueries = _asInt(decoded?['SuccessfulQueries']) ?? 0;
    final httpStatusCode = _asInt(decoded?['HttpStatusCode']);
    return WindowsDnsTestResult(
      success:
          result.exitCode == 0 && decoded != null && decoded['Success'] == true,
      successfulQueries: successfulQueries,
      addresses: _asStringList(decoded?['Addresses']),
      httpStatusCode: httpStatusCode,
      error: decoded?['Error']?.toString(),
      logs: <String>[
        '[dns] DNS test: $successfulQueries/$safeAttempts successful queries.',
        '[dns] CDN probe HTTP status: ${httpStatusCode ?? 'unavailable'}.',
      ],
    );
  }

  File get _backupFile {
    final override = _backupFileOverride;
    if (override != null) return override;
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
    final base = localAppData == null || localAppData.isEmpty
        ? Directory.systemTemp.path
        : localAppData;
    return File(
      path.join(base, 'neuravpn', 'network', 'windows_dns_backup.json'),
    );
  }

  Future<Map<String, dynamic>?> _readBackup() async {
    try {
      final raw = jsonDecode(await _backupFile.readAsString());
      if (raw is Map) return raw.cast<String, dynamic>();
    } catch (_) {
      // The caller reports a stable backup error and keeps the file.
    }
    return null;
  }

  String _captureStateScript(int interfaceIndex) {
    final serversJson = jsonEncode(secureDnsServers);
    return '''
\$interface = & {
${_captureInterfaceBody(interfaceIndex)}
}
\$managedServers = ConvertFrom-Json @'
$serversJson
'@
\$doh = @()
if (Get-Command Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
  foreach (\$server in @(\$managedServers)) {
    \$entry = Get-DnsClientDohServerAddress -ServerAddress \$server -ErrorAction SilentlyContinue
    if (\$entry) {
      \$doh += [pscustomobject]@{
        ServerAddress = \$server
        Existed = \$true
        DohTemplate = \$entry.DohTemplate
        AllowFallbackToUdp = [bool]\$entry.AllowFallbackToUdp
        AutoUpgrade = [bool]\$entry.AutoUpgrade
      }
    } else {
      \$doh += [pscustomobject]@{ ServerAddress = \$server; Existed = \$false }
    }
  }
}
[pscustomobject]@{
  Interfaces = @(\$interface)
  Doh = @(\$doh)
} | ConvertTo-Json -Depth 6 -Compress
''';
  }

  String _captureInterfaceScript(int interfaceIndex) {
    return '''
\$interface = & {
${_captureInterfaceBody(interfaceIndex)}
}
\$interface | ConvertTo-Json -Compress
''';
  }

  String _captureInterfaceBody(int interfaceIndex) {
    return '''
\$interface = Get-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
  Select-Object -First 1
if (-not \$interface) { throw 'dns_interface_not_found:$interfaceIndex' }
\$dns = Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction Stop
[pscustomobject]@{
  InterfaceIndex = $interfaceIndex
  InterfaceAlias = \$interface.InterfaceAlias
  ServerAddresses = @(\$dns.ServerAddresses)
}
''';
  }

  String _applyScript(List<int> interfaceIndexes) {
    final targetsJson = jsonEncode(interfaceIndexes);
    final serversJson = jsonEncode(secureDnsServers);
    return '''
\$ErrorActionPreference = 'Stop'
\$managedRuleName = '$managedRuleName'
\$targets = ConvertFrom-Json @'
$targetsJson
'@
\$servers = ConvertFrom-Json @'
$serversJson
'@
try {
  foreach (\$index in @(\$targets | Sort-Object -Unique)) {
    \$iface = Get-NetIPInterface -InterfaceIndex \$index -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (\$iface) {
      Set-DnsClientServerAddress -InterfaceIndex \$index -ServerAddresses @(\$servers) -ErrorAction Stop
    }
  }
  if (-not (Get-Command Set-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) {
    throw 'windows_doh_not_supported'
  }
  foreach (\$server in @(\$servers)) {
    Set-DnsClientDohServerAddress -ServerAddress \$server -DohTemplate '$dohTemplate' -AllowFallbackToUdp \$false -AutoUpgrade \$true -ErrorAction Stop
  }
  if (-not (Get-Command Add-DnsClientNrptRule -ErrorAction SilentlyContinue)) {
    throw 'windows_nrpt_not_supported'
  }
  \$existingManagedRules = @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
    Where-Object {
      \$_.DisplayName -eq \$managedRuleName -and
      \$_.Comment -eq \$managedRuleName
    })
  foreach (\$rule in \$existingManagedRules) {
    Remove-DnsClientNrptRule -Name \$rule.Name -Force -ErrorAction Stop
  }
  Add-DnsClientNrptRule -Namespace '.' -NameServers @(\$servers) -DisplayName \$managedRuleName -Comment \$managedRuleName -ErrorAction Stop | Out-Null
  Clear-DnsClientCache -ErrorAction SilentlyContinue
  \$addresses = @()
  \$lastError = \$null
  for (\$attempt = 0; \$attempt -lt 5 -and \$addresses.Count -eq 0; \$attempt++) {
    try {
      \$addresses = @(Resolve-DnsName -Name 'tr.rbxcdn.com' -Type A -DnsOnly -ErrorAction Stop |
        Where-Object { \$_.IPAddress } |
        Select-Object -ExpandProperty IPAddress)
    } catch {
      \$lastError = \$_.Exception.Message
      Start-Sleep -Milliseconds 250
    }
  }
  if (\$addresses.Count -eq 0) {
    throw "dns_probe_failed: \$lastError"
  }
  [pscustomobject]@{
    Success = \$true
    Addresses = @(\$addresses | Sort-Object -Unique)
  } | ConvertTo-Json -Compress
} catch {
  [pscustomobject]@{ Success = \$false; Error = \$_.Exception.Message } |
    ConvertTo-Json -Compress
}
''';
  }

  String _restoreScript(Map<String, dynamic> state) {
    final interfacesJson = jsonEncode(_asMapList(state['Interfaces']));
    final dohJson = jsonEncode(_asMapList(state['Doh']));
    return '''
\$ErrorActionPreference = 'Stop'
\$managedRuleName = '$managedRuleName'
\$interfaces = ConvertFrom-Json @'
$interfacesJson
'@
\$doh = ConvertFrom-Json @'
$dohJson
'@
try {
  if (Get-Command Get-DnsClientNrptRule -ErrorAction SilentlyContinue) {
    \$managedRules = @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
      Where-Object {
        \$_.DisplayName -eq \$managedRuleName -and
        \$_.Comment -eq \$managedRuleName
      })
    foreach (\$rule in \$managedRules) {
      Remove-DnsClientNrptRule -Name \$rule.Name -Force -ErrorAction Stop
    }
  }
  foreach (\$item in @(\$interfaces)) {
    \$index = [int]\$item.InterfaceIndex
    \$iface = Get-NetIPInterface -InterfaceIndex \$index -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not \$iface) { continue }
    \$servers = @(\$item.ServerAddresses | Where-Object { \$_ })
    if (\$servers.Count -gt 0) {
      Set-DnsClientServerAddress -InterfaceIndex \$index -ServerAddresses \$servers -ErrorAction Stop
    } else {
      Set-DnsClientServerAddress -InterfaceIndex \$index -ResetServerAddresses -ErrorAction Stop
    }
  }
  if (Get-Command Set-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
    foreach (\$item in @(\$doh)) {
      if ([bool]\$item.Existed) {
        Set-DnsClientDohServerAddress -ServerAddress \$item.ServerAddress -DohTemplate \$item.DohTemplate -AllowFallbackToUdp ([bool]\$item.AllowFallbackToUdp) -AutoUpgrade ([bool]\$item.AutoUpgrade) -ErrorAction Stop
      } elseif (Get-Command Remove-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
        Remove-DnsClientDohServerAddress -ServerAddress \$item.ServerAddress -ErrorAction SilentlyContinue
      }
    }
  }
  Clear-DnsClientCache -ErrorAction SilentlyContinue
  [pscustomobject]@{ Success = \$true } | ConvertTo-Json -Compress
} catch {
  [pscustomobject]@{ Success = \$false; Error = \$_.Exception.Message } |
    ConvertTo-Json -Compress
}
''';
  }

  Future<ProcessResult> _runPowerShell(String script) {
    return _processRunner('powershell', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
  }

  Map<String, dynamic>? _decodeMap(Object? raw) {
    try {
      final decoded = jsonDecode(raw.toString().trim());
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {
      // Return null to the caller.
    }
    return null;
  }

  List<Map<String, dynamic>> _asMapList(Object? value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
    }
    if (value is Map) {
      return <Map<String, dynamic>>[value.cast<String, dynamic>()];
    }
    return <Map<String, dynamic>>[];
  }

  List<String> _asStringList(Object? value) {
    if (value is List) {
      return value.map((item) => item.toString()).toList();
    }
    if (value == null) return <String>[];
    return <String>[value.toString()];
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse('${value ?? ''}');
  }

  String _resultDetails(ProcessResult result) {
    final stderr = result.stderr.toString().trim();
    if (stderr.isNotEmpty) return stderr;
    final stdout = result.stdout.toString().trim();
    if (stdout.isNotEmpty) return stdout;
    return 'exit code ${result.exitCode}';
  }

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments);
  }
}
