import 'dart:async';
import 'dart:io';
import 'dart:math';

typedef TunProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class TunAdapterInfo {
  const TunAdapterInfo({
    required this.name,
    required this.hidden,
    required this.status,
  });

  final String name;
  final bool hidden;
  final String status;
}

class TunCleanupResult {
  const TunCleanupResult({
    required this.success,
    required this.removed,
    required this.stillPresent,
    required this.logs,
    this.errorCode,
  });

  final bool success;
  final bool removed;
  final bool stillPresent;
  final List<String> logs;
  final String? errorCode;
}

class TunBulkCleanupResult {
  const TunBulkCleanupResult({
    required this.success,
    required this.cleanedAdapters,
    required this.stillPresentAdapters,
    required this.logs,
    this.errorCode,
  });

  final bool success;
  final List<String> cleanedAdapters;
  final List<String> stillPresentAdapters;
  final List<String> logs;
  final String? errorCode;
}

class TunSessionPlan {
  const TunSessionPlan({
    required this.success,
    required this.requiresElevation,
    required this.inboundTag,
    required this.interfaceName,
    required this.addresses,
    required this.logs,
    required this.staleAdapters,
    required this.discoveredAdapters,
    this.error,
  });

  final bool success;
  final bool requiresElevation;
  final String inboundTag;
  final String interfaceName;
  final List<String> addresses;
  final List<String> logs;
  final List<String> staleAdapters;
  final List<TunAdapterInfo> discoveredAdapters;
  final String? error;
}

class WindowsTunGuard {
  WindowsTunGuard({
    this.removalTimeout = const Duration(seconds: 8),
    this.pollInterval = const Duration(milliseconds: 250),
    this.cleanupBudget = const Duration(seconds: 15),
    this.adapterUpTimeout = const Duration(seconds: 30),
    TunProcessRunner? processRunner,
    bool? isWindowsOverride,
    Future<bool> Function()? elevationChecker,
    DateTime Function()? clock,
    int Function(int max)? randomInt,
  }) : _processRunner = processRunner ?? _defaultProcessRunner,
       _isWindowsOverride = isWindowsOverride,
       _elevationChecker = elevationChecker,
       _clock = clock ?? DateTime.now,
       _randomInt = randomInt ?? Random().nextInt;

  static const String defaultInboundTag = 'tun-in';
  static const String defaultInterfaceName = 'wintun0';
  static const List<String> _defaultAddresses = ['172.19.0.1/30'];

  final Duration removalTimeout;
  final Duration pollInterval;
  final Duration cleanupBudget;
  final Duration adapterUpTimeout;
  final TunProcessRunner _processRunner;
  final bool? _isWindowsOverride;
  final Future<bool> Function()? _elevationChecker;
  final DateTime Function() _clock;
  final int Function(int max) _randomInt;
  int _sessionCounter = 0;

  bool get _isWindows => _isWindowsOverride ?? Platform.isWindows;

  Future<TunSessionPlan> prepare() async {
    if (!_isWindows) {
      return TunSessionPlan(
        success: true,
        requiresElevation: false,
        inboundTag: defaultInboundTag,
        interfaceName: defaultInterfaceName,
        addresses: _defaultAddresses,
        logs: const ['Non-Windows OS detected, TUN guard skipped'],
        staleAdapters: const [],
        discoveredAdapters: const [],
      );
    }

    final logs = <String>[];
    if (!await _isElevated()) {
      logs.add('Administrator privileges are required to manage TUN adapters.');
      return TunSessionPlan(
        success: false,
        requiresElevation: true,
        inboundTag: defaultInboundTag,
        interfaceName: defaultInterfaceName,
        addresses: _defaultAddresses,
        logs: logs,
        staleAdapters: const [],
        discoveredAdapters: const [],
        error: 'Run the application as Administrator',
      );
    }

    final discovered = await _listTunAdapters(logs);
    final staleAdapters = discovered.map((e) => e.name).toSet().toList();
    if (staleAdapters.isEmpty) {
      logs.add('No stale TUN adapters detected (including hidden adapters).');
    } else {
      logs.add(
        'Stale TUN adapters detected: ${staleAdapters.join(', ')} '
        '(hidden: ${discovered.where((e) => e.hidden).length})',
      );
    }

    var sessionName = _buildSessionInterfaceName();
    while (staleAdapters.contains(sessionName)) {
      sessionName = _buildSessionInterfaceName();
    }
    final addresses = _buildRandomAddresses();
    logs.add(
      'Allocated session interface: $sessionName '
      'with subnet ${addresses.join(', ')}',
    );

    return TunSessionPlan(
      success: true,
      requiresElevation: false,
      inboundTag: sessionName,
      interfaceName: sessionName,
      addresses: addresses,
      logs: logs,
      staleAdapters: staleAdapters,
      discoveredAdapters: discovered,
    );
  }

  Future<TunCleanupResult> cleanupAdapter(String? interfaceName) async {
    if (!_isWindows || interfaceName == null || interfaceName.isEmpty) {
      return const TunCleanupResult(
        success: true,
        removed: false,
        stillPresent: false,
        logs: [],
      );
    }

    final logs = <String>['Cleanup requested for $interfaceName'];
    if (!await _adapterExists(interfaceName)) {
      logs.add('Adapter $interfaceName already absent.');
      return TunCleanupResult(
        success: true,
        removed: true,
        stillPresent: false,
        logs: logs,
      );
    }

    final removed = await _removeAdapterPipeline(
      interfaceName,
      logs,
      waitTimeout: removalTimeout,
    );
    if (!removed) {
      return TunCleanupResult(
        success: false,
        removed: false,
        stillPresent: true,
        logs: logs,
        errorCode: 'adapter_still_present',
      );
    }

    return TunCleanupResult(
      success: true,
      removed: true,
      stillPresent: false,
      logs: logs,
    );
  }

  Future<TunBulkCleanupResult> cleanupAdapters(List<String> adapters) async {
    if (!_isWindows || adapters.isEmpty) {
      return const TunBulkCleanupResult(
        success: true,
        cleanedAdapters: [],
        stillPresentAdapters: [],
        logs: [],
      );
    }

    final uniq = adapters.toSet().toList();
    final logs = <String>['Bulk cleanup requested for ${uniq.join(', ')}'];
    final cleaned = <String>[];
    final stillPresent = <String>[];
    final stopwatch = Stopwatch()..start();

    for (final adapter in uniq) {
      final remaining = cleanupBudget - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        logs.add(
          'Cleanup budget exceeded; unresolved adapters: '
          '${uniq.where((name) => !cleaned.contains(name)).join(', ')}',
        );
        break;
      }
      final result = await cleanupAdapter(adapter);
      logs.addAll(result.logs);
      if (result.success) {
        cleaned.add(adapter);
      } else if (result.stillPresent) {
        stillPresent.add(adapter);
      }
    }

    final success = stillPresent.isEmpty;
    if (success) {
      logs.add('Bulk cleanup completed; removed ${cleaned.length} adapters.');
    } else {
      logs.add('Bulk cleanup incomplete; still present: ${stillPresent.join(', ')}');
    }

    return TunBulkCleanupResult(
      success: success,
      cleanedAdapters: cleaned,
      stillPresentAdapters: stillPresent,
      logs: logs,
      errorCode: success ? null : 'adapter_still_present',
    );
  }

  Future<TunBulkCleanupResult> cleanupStaleTunAdapters({
    Set<String> excludeNames = const <String>{},
  }) async {
    if (!_isWindows) {
      return const TunBulkCleanupResult(
        success: true,
        cleanedAdapters: [],
        stillPresentAdapters: [],
        logs: [],
      );
    }
    final logs = <String>['Cleanup stale adapters requested.'];
    final adapters = await _listTunAdapters(logs);
    final target = adapters
        .map((e) => e.name)
        .where((name) => !excludeNames.contains(name))
        .toList();
    if (target.isEmpty) {
      logs.add('No stale adapters to clean.');
      return TunBulkCleanupResult(
        success: true,
        cleanedAdapters: const [],
        stillPresentAdapters: const [],
        logs: logs,
      );
    }
    final bulk = await cleanupAdapters(target);
    return TunBulkCleanupResult(
      success: bulk.success,
      cleanedAdapters: bulk.cleanedAdapters,
      stillPresentAdapters: bulk.stillPresentAdapters,
      logs: [...logs, ...bulk.logs],
      errorCode: bulk.errorCode,
    );
  }

  Future<bool> waitForAdapterUp(String name, {Duration? timeout}) async {
    if (!_isWindows) return true;
    if (name.isEmpty) return false;
    final limit = timeout ?? adapterUpTimeout;
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      final status = await _readAdapterStatus(name);
      if (status == 'up') {
        return true;
      }
      await Future.delayed(pollInterval);
    }
    return false;
  }

  Future<List<TunAdapterInfo>> _listTunAdapters(List<String> logs) async {
    const includeHiddenCommand = r'''
Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
Where-Object { $_.Name -like 'tun-in*' -or $_.Name -like 'wintun*' } |
ForEach-Object { "$($_.Name)|$($_.Status)" }
''';
    const visibleOnlyCommand =
        "Get-NetAdapter -ErrorAction SilentlyContinue | "
        "Where-Object { \$_.Name -like 'tun-in*' -or \$_.Name -like 'wintun*' } | "
        "Select-Object -ExpandProperty Name";
    const cimFallbackCommand = r'''
Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
Where-Object { $_.NetConnectionID -like 'tun-in*' -or $_.NetConnectionID -like 'wintun*' } |
ForEach-Object { "$($_.NetConnectionID)|$($_.NetEnabled)" }
''';

    final includeHidden = await _runPowerShell(includeHiddenCommand, logs);
    final visible = await _runPowerShell(visibleOnlyCommand, logs);

    final visibleSet = _parseLines(visible.stdout).toSet();
    final parsed = _parseAdapterLines(includeHidden.stdout, visibleSet);
    if (parsed.isNotEmpty) {
      return parsed;
    }

    logs.add('Get-NetAdapter returned no adapters. Falling back to CIM query.');
    final cimResult = await _runPowerShell(cimFallbackCommand, logs);
    return _parseCimAdapterLines(cimResult.stdout, visibleSet);
  }

  Future<bool> _waitForAdapterRemoval(
    String name,
    List<String>? logs, {
    Duration? timeout,
  }) async {
    final limit = timeout ?? removalTimeout;
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      if (!await _adapterExists(name)) {
        logs?.add('Adapter $name removed.');
        return true;
      }
      await Future.delayed(pollInterval);
    }
    logs?.add('Adapter $name is still present after ${limit.inSeconds}s.');
    return false;
  }

  Future<bool> _adapterExists(String name) async {
    final command =
        "if (Get-NetAdapter -Name '${_escapePs(name)}' -IncludeHidden -ErrorAction SilentlyContinue) { Write-Output 'True' } else { Write-Output 'False' }";
    final result = await _runPowerShell(command, null);
    if (result.stdout == null) return false;
    return result.stdout.toString().toLowerCase().contains('true');
  }

  Future<String> _readAdapterStatus(String name) async {
    final command =
        "Get-NetAdapter -Name '${_escapePs(name)}' -IncludeHidden -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Status";
    final result = await _runPowerShell(command, null);
    if (result.stdout == null) return '';
    return result.stdout.toString().trim().toLowerCase();
  }

  Future<bool> _removeAdapterPipeline(
    String adapter,
    List<String> logs, {
    Duration? waitTimeout,
  }) async {
    var success = true;

    final disable = await _runNetsh(
      ['interface', 'set', 'interface', 'name="$adapter"', 'admin=disabled'],
      logs,
    );
    if (disable.exitCode != 0) success = false;

    final delete = await _runNetsh(
      ['interface', 'ipv4', 'delete', 'interface', 'name="$adapter"'],
      logs,
    );
    if (delete.exitCode != 0) success = false;
    final deleteIpv6 = await _runNetsh(
      ['interface', 'ipv6', 'delete', 'interface', 'name="$adapter"'],
      logs,
    );
    if (deleteIpv6.exitCode != 0) success = false;

    await _releaseAdapterAddresses(adapter, logs);

    final remove = await _runPowerShell(
      "Import-Module NetAdapter -ErrorAction SilentlyContinue; Remove-NetAdapter -Name '${_escapePs(adapter)}' -Confirm:\$false -Force",
      logs,
    );
    if (remove.exitCode != 0) {
      success = false;
      await _runPowerShell(
        "Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | "
        "Where-Object { \$_.NetConnectionID -eq '${_escapePs(adapter)}' } | "
        "ForEach-Object { Invoke-CimMethod -InputObject \$_ -MethodName Disable -ErrorAction SilentlyContinue | Out-Null; "
        "Invoke-CimMethod -InputObject \$_ -MethodName Delete -ErrorAction SilentlyContinue | Out-Null }",
        logs,
      );
    }

    final waitResult = await _waitForAdapterRemoval(
      adapter,
      logs,
      timeout: waitTimeout,
    );
    if (!waitResult) success = false;

    return success;
  }

  Future<void> _releaseAdapterAddresses(String adapter, List<String> logs) async {
    final command =
        "Import-Module NetTCPIP -ErrorAction SilentlyContinue; Get-NetIPAddress -InterfaceAlias '${_escapePs(adapter)}' -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:\$false";
    final result = await _runPowerShell(command, logs);
    if (result.exitCode == 0) {
      logs.add('Cleared IP addresses on $adapter');
    }
  }

  Future<bool> _isElevated() async {
    if (_elevationChecker != null) {
      return _elevationChecker.call();
    }
    try {
      final result = await _processRunner('powershell', [
        '-NoProfile',
        '-Command',
        '([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
      ]);
      if (result.stdout == null) return false;
      return result.stdout.toString().toLowerCase().contains('true');
    } catch (_) {
      return false;
    }
  }

  Future<ProcessResult> _runNetsh(List<String> args, List<String>? logs) async {
    try {
      final result = await _processRunner('netsh', args);
      logs?.add('netsh ${args.join(' ')} => ${result.exitCode}');
      final stderr = _cleanOutput(result.stderr);
      if (result.exitCode != 0 && stderr.isNotEmpty) {
        logs?.add('  stderr: $stderr');
      }
      return result;
    } catch (e) {
      logs?.add('netsh ${args.join(' ')} failed: $e');
      return ProcessResult(-1, 1, '', '$e');
    }
  }

  Future<ProcessResult> _runPowerShell(String command, List<String>? logs) async {
    try {
      final result = await _processRunner('powershell', [
        '-NoProfile',
        '-Command',
        command,
      ]);
      logs?.add('powershell: ${command.split('\n').first} => ${result.exitCode}');
      final stderr = _cleanOutput(result.stderr);
      if (result.exitCode != 0 && stderr.isNotEmpty) {
        logs?.add('  stderr: $stderr');
      }
      return result;
    } catch (e) {
      logs?.add('PowerShell failed: $e');
      return ProcessResult(-1, 1, '', '$e');
    }
  }

  String _buildSessionInterfaceName() {
    _sessionCounter++;
    final nowHex = _clock().millisecondsSinceEpoch.toRadixString(16);
    final randomHex = _randomInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'tun-in-${nowHex.substring(nowHex.length - 6)}-${_sessionCounter.toRadixString(16)}$randomHex';
  }

  List<String> _buildRandomAddresses() {
    final thirdOctet = 16 + _randomInt(200);
    final block = _randomInt(64) * 4;
    final host = block + 1;
    final ip = '172.25.$thirdOctet.$host/30';
    return [ip];
  }

  String _cleanOutput(Object? value) {
    if (value == null) return '';
    final text = value.toString().trim();
    if (text.length > 400) {
      return text.substring(0, 400);
    }
    return text;
  }

  String _escapePs(String input) => input.replaceAll("'", "''");

  List<TunAdapterInfo> _parseAdapterLines(Object? output, Set<String> visibleSet) {
    final result = <TunAdapterInfo>[];
    for (final line in _parseLines(output)) {
      final parts = line.split('|');
      if (parts.isEmpty) continue;
      final name = parts[0].trim();
      if (name.isEmpty) continue;
      final status = parts.length > 1 ? parts[1].trim().toLowerCase() : '';
      result.add(
        TunAdapterInfo(
          name: name,
          hidden: !visibleSet.contains(name),
          status: status,
        ),
      );
    }
    return result;
  }

  List<TunAdapterInfo> _parseCimAdapterLines(Object? output, Set<String> visibleSet) {
    final result = <TunAdapterInfo>[];
    for (final line in _parseLines(output)) {
      final parts = line.split('|');
      if (parts.isEmpty) continue;
      final name = parts[0].trim();
      if (name.isEmpty) continue;
      final enabled = parts.length > 1 ? parts[1].trim().toLowerCase() : '';
      final status = enabled == 'true' ? 'up' : 'down';
      result.add(
        TunAdapterInfo(
          name: name,
          hidden: !visibleSet.contains(name),
          status: status,
        ),
      );
    }
    return result;
  }

  List<String> _parseLines(Object? output) {
    if (output == null) return const <String>[];
    return output
        .toString()
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments);
  }
}
