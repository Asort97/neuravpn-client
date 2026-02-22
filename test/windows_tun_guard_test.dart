import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/windows_tun_guard.dart';

void main() {
  ProcessResult okResult([String stdout = '']) =>
      ProcessResult(1, 0, stdout, '');

  test('prepare detects hidden adapters and exposes stale list', () async {
    Future<ProcessResult> runner(String executable, List<String> arguments) async {
      if (executable != 'powershell') return okResult();
      final command = arguments.last;
      if (command.contains('Get-NetAdapter -IncludeHidden')) {
        return okResult('wintun0|Up\ntun-in-visible|Down\n');
      }
      if (command.contains('Get-NetAdapter -ErrorAction SilentlyContinue') &&
          command.contains('Select-Object -ExpandProperty Name')) {
        return okResult('tun-in-visible\n');
      }
      return okResult();
    }

    final guard = WindowsTunGuard(
      processRunner: runner,
      isWindowsOverride: true,
      elevationChecker: () async => true,
      randomInt: (_) => 1,
      clock: () => DateTime(2026, 2, 21, 20, 0, 0),
    );

    final plan = await guard.prepare();
    expect(plan.success, isTrue);
    expect(plan.discoveredAdapters.length, 2);
    expect(
      plan.discoveredAdapters.any(
        (adapter) => adapter.name == 'wintun0' && adapter.hidden,
      ),
      isTrue,
    );
    expect(plan.staleAdapters, contains('wintun0'));
    expect(plan.staleAdapters, contains('tun-in-visible'));
    expect(plan.interfaceName, startsWith('tun-in-'));
  });

  test('cleanupAdapter reports stillPresent when adapter cannot be removed', () async {
    Future<ProcessResult> runner(String executable, List<String> arguments) async {
      if (executable != 'powershell') {
        return okResult();
      }
      final command = arguments.last;
      if (command.contains("if (Get-NetAdapter -Name 'wintun0'")) {
        return okResult('True');
      }
      return okResult();
    }

    final guard = WindowsTunGuard(
      processRunner: runner,
      isWindowsOverride: true,
      elevationChecker: () async => true,
      removalTimeout: const Duration(milliseconds: 30),
      pollInterval: const Duration(milliseconds: 5),
    );

    final result = await guard.cleanupAdapter('wintun0');
    expect(result.success, isFalse);
    expect(result.stillPresent, isTrue);
    expect(result.errorCode, 'adapter_still_present');
    expect(
      result.logs.any((line) => line.contains('still present')),
      isTrue,
    );
  });

  test('prepare allocates unique session interface names', () async {
    Future<ProcessResult> runner(String executable, List<String> arguments) async {
      return okResult();
    }

    final guard = WindowsTunGuard(
      processRunner: runner,
      isWindowsOverride: true,
      elevationChecker: () async => true,
      randomInt: (_) => 42,
      clock: () => DateTime(2026, 2, 21, 20, 0, 0),
    );

    final first = await guard.prepare();
    final second = await guard.prepare();

    expect(first.interfaceName, isNot(second.interfaceName));
    expect(first.addresses.first, startsWith('172.25.'));
    expect(second.addresses.first, startsWith('172.25.'));
  });
}
