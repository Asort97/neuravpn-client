import 'dart:async';
import 'dart:io';
import 'dart:math';

class TunPreparationResult {
  const TunPreparationResult({
    required this.success,
    required this.requiresElevation,
    required this.inboundTag,
    required this.interfaceName,
    required this.addresses,
    required this.logs,
    required this.leftoverAdapters,
    this.error,
  });

  final bool success;
  final bool requiresElevation;
  final String inboundTag;
  final String interfaceName;
  final List<String> addresses;
  final List<String> logs;
  final List<String> leftoverAdapters;
  final String? error;
}

class WindowsTunGuard {
  WindowsTunGuard({
    this.removalTimeout = const Duration(seconds: 3),
    this.pollInterval = const Duration(milliseconds: 250),
    this.cleanupBudget = const Duration(seconds: 6),
  });

  static const String defaultInboundTag = 'tun-in';
  static const String defaultInterfaceName = 'wintun0';
  static const List<String> _defaultAddresses = ['172.19.0.1/30'];

  final Duration removalTimeout;
  final Duration pollInterval;
  final Duration cleanupBudget;
  final Random _random = Random();

  Future<TunPreparationResult> prepare() async {
    if (!Platform.isWindows) {
      return TunPreparationResult(
        success: true,
        requiresElevation: false,
        inboundTag: defaultInboundTag,
        interfaceName: defaultInterfaceName,
        addresses: _defaultAddresses,
        logs: const ['Non-Windows OS detected, TUN guard skipped'],
        leftoverAdapters: const [],
      );
    }

    final logs = <String>[];
    if (!await _isElevated()) {
      logs.add('Administrator privileges are required to manage TUN adapters.');
      return TunPreparationResult(
        success: false,
        requiresElevation: true,
        inboundTag: defaultInboundTag,
        interfaceName: defaultInterfaceName,
        addresses: _defaultAddresses,
        logs: logs,
        leftoverAdapters: const [],
        error: 'Run the application as Administrator',
      );
    }

    final conflicts = await _findConflictingAdapters(logs);
    if (conflicts.isEmpty) {
      logs.add('No conflicting TUN adapters detected.');
      return TunPreparationResult(
        success: true,
        requiresElevation: false,
        inboundTag: defaultInboundTag,
        interfaceName: defaultInterfaceName,
        addresses: _defaultAddresses,
        logs: logs,
        leftoverAdapters: const [],
      );
    }

    logs.add('Conflicting adapters detected: ${conflicts.join(', ')}');
    final fallbackName = _buildFallbackName();
    final randomAddresses = _buildRandomAddresses();
    logs.add('Fast path selected: using $fallbackName with subnet ${randomAddresses.join(', ')}');
    return TunPreparationResult(
      success: true,
      requiresElevation: false,
      inboundTag: fallbackName,
      interfaceName: fallbackName,
      addresses: randomAddresses,
      logs: logs,
      leftoverAdapters: conflicts,
    );
  }

  Future<List<String>> cleanupAdapter(String? interfaceName) async {
    if (!Platform.isWindows || interfaceName == null || interfaceName.isEmpty) {
      return const [];
    }

    final logs = <String>['Cleanup requested for $interfaceName'];
    if (!await _adapterExists(interfaceName)) {
      logs.add('Adapter $interfaceName already absent.');
      return logs;
    }

    await _removeAdapter(interfaceName, logs, waitTimeout: removalTimeout);
    return logs;
  }

  Future<List<String>> cleanupAdapters(List<String> adapters) async {
    if (!Platform.isWindows || adapters.isEmpty) {
      return const [];
    }

    final logs = <String>['Bulk cleanup requested for ${adapters.join(', ')}'];
    await _cleanupWithBudget(adapters, logs);
    return logs;
  }

  Future<List<String>> _findConflictingAdapters(List<String> logs) async {
    const command =
        "Get-NetAdapter | Where-Object { \$_.Name -like 'tun-in*' -or \$_.Name -like 'wintun*' } | Select-Object -ExpandProperty Name";
    final result = await _runPowerShell(command, logs);
    if (result == null || result.stdout == null) return [];
    final stdout = result.stdout.toString();
    final names = stdout
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    return names;
  }

  Future<bool> _waitForAdapterRemoval(String name, List<String>? logs, {Duration? timeout}) async {
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
        "if (Get-NetAdapter -Name '${_escapePs(name)}' -ErrorAction SilentlyContinue) { Write-Output 'True' } else { Write-Output 'False' }";
    final result = await _runPowerShell(command, null);
    if (result == null || result.stdout == null) return false;
    return result.stdout.toString().toLowerCase().contains('true');
  }

  Future<bool> _cleanupWithBudget(List<String> adapters, List<String> logs) async {
    if (adapters.isEmpty) return true;
    final stopwatch = Stopwatch()..start();
    var removedCount = 0;

    for (final adapter in adapters) {
      final remaining = cleanupBudget - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        logs.add('Cleanup budget exceeded after removing $removedCount adapter(s).');
        return false;
      }

      final waitTimeout = remaining < removalTimeout ? remaining : removalTimeout;
      final removed = await _removeAdapter(adapter, logs, waitTimeout: waitTimeout);
      if (!removed) {
        logs.add('Stopping cleanup loop early because $adapter is still present.');
        return false;
      }
      removedCount++;
    }

    logs.add('Removed $removedCount adapter(s) within ${stopwatch.elapsed.inSeconds}s.');
    return true;
  }

  Future<bool> _removeAdapter(String adapter, List<String> logs, {Duration? waitTimeout}) async {
    var success = true;

    final disable = await _runNetsh(
      ['interface', 'set', 'interface', 'name="$adapter"', 'admin=disabled'],
      logs,
    );
    if (disable?.exitCode != 0) success = false;

    final delete = await _runNetsh(
      ['interface', 'ipv4', 'delete', 'interface', 'name="$adapter"'],
      logs,
    );
    if (delete?.exitCode != 0) success = false;

    await _releaseAdapterAddresses(adapter, logs);

    final remove = await _runPowerShell(
      "Import-Module NetAdapter -ErrorAction SilentlyContinue; Remove-NetAdapter -Name '${_escapePs(adapter)}' -Confirm:\$false -Force",
      logs,
    );
    if (remove?.exitCode != 0) success = false;

    final waitResult = await _waitForAdapterRemoval(adapter, logs, timeout: waitTimeout);
    if (!waitResult) success = false;

    return success;
  }

  Future<void> _releaseAdapterAddresses(String adapter, List<String> logs) async {
    final command =
        "Import-Module NetTCPIP -ErrorAction SilentlyContinue; Get-NetIPAddress -InterfaceAlias '${_escapePs(adapter)}' -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:\$false";
    final result = await _runPowerShell(command, logs);
    if (result != null && result.exitCode == 0) {
      logs.add('Cleared IP addresses on $adapter');
    }
  }

  Future<bool> _isElevated() async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)'
      ]);
      if (result.stdout == null) return false;
      return result.stdout.toString().toLowerCase().contains('true');
    } catch (_) {
      return false;
    }
  }

  Future<ProcessResult?> _runNetsh(List<String> args, List<String>? logs) async {
    try {
      final result = await Process.run('netsh', args);
      logs?.add('netsh ${args.join(' ')} => ${result.exitCode}');
      final stderr = _cleanOutput(result.stderr);
      if (result.exitCode != 0 && stderr.isNotEmpty) {
        logs?.add('  stderr: $stderr');
      }
      return result;
    } catch (e) {
      logs?.add('netsh ${args.join(' ')} failed: $e');
      return null;
    }
  }

  Future<ProcessResult?> _runPowerShell(String command, List<String>? logs) async {
    try {
      final result = await Process.run('powershell', ['-NoProfile', '-Command', command]);
      logs?.add('powershell: ${command.split('\n').first} => ${result.exitCode}');
      final stderr = _cleanOutput(result.stderr);
      if (result.exitCode != 0 && stderr.isNotEmpty) {
        logs?.add('  stderr: $stderr');
      }
      return result;
    } catch (e) {
      logs?.add('PowerShell failed: $e');
      return null;
    }
  }

  String _buildFallbackName() {
    final suffix = _random.nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'tun-in-$suffix';
  }

  List<String> _buildRandomAddresses() {
    final thirdOctet = 16 + _random.nextInt(200); // 16..215 avoids clashes with default
    final block = _random.nextInt(64) * 4; // /30 block start within 0..252
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
}
