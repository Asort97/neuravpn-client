import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/windows_tun_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProcessResult okResult([String stdout = '']) =>
      ProcessResult(1, 0, stdout, '');

  test('prepare detects hidden adapters and exposes stale list', () async {
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments,
    ) async {
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

    final plan = await guard.prepare(detectExistingAdapters: true);
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

  test(
    'cleanupAdapter reports stillPresent when adapter cannot be removed',
    () async {
      Future<ProcessResult> runner(
        String executable,
        List<String> arguments,
      ) async {
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
      expect(result.logs.any((line) => line.contains('still present')), isTrue);
    },
  );

  test('prepare allocates unique session interface names', () async {
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments,
    ) async {
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

  test('prepare reuses positive elevation check', () async {
    var elevationChecks = 0;
    final guard = WindowsTunGuard(
      processRunner: (executable, arguments) async => okResult(),
      isWindowsOverride: true,
      elevationChecker: () async {
        elevationChecks += 1;
        return true;
      },
      randomInt: (_) => 7,
      clock: () => DateTime(2026, 2, 21, 20, 0, 0),
    );

    await guard.warmupElevationCheck();
    final first = await guard.prepare();
    final second = await guard.prepare();

    expect(first.success, isTrue);
    expect(second.success, isTrue);
    expect(elevationChecks, 1);
  });

  test('concurrent elevation callers share one check', () async {
    final gate = Completer<bool>();
    var elevationChecks = 0;
    final guard = WindowsTunGuard(
      processRunner: (executable, arguments) async => okResult(),
      isWindowsOverride: true,
      elevationChecker: () {
        elevationChecks += 1;
        return gate.future;
      },
    );

    final warmup = guard.warmupElevationCheck();
    final prepare = guard.prepare();
    await Future<void>.delayed(Duration.zero);

    expect(elevationChecks, 1);
    gate.complete(true);
    expect(await warmup, isTrue);
    expect((await prepare).success, isTrue);
  });

  test('prepare rejects a definitive non-elevated process', () async {
    final guard = WindowsTunGuard(
      processRunner: (executable, arguments) async => okResult(),
      isWindowsOverride: true,
      elevationChecker: () async => false,
    );

    final plan = await guard.prepare();

    expect(plan.success, isFalse);
    expect(plan.requiresElevation, isTrue);
    expect(guard.isElevationConfirmed, isFalse);
    expect(guard.elevationState, isFalse);
  });

  test(
    'prepare does not reject when elevation diagnostic is unavailable',
    () async {
      final guard = WindowsTunGuard(
        processRunner: (executable, arguments) async =>
            ProcessResult(1, 1, '', 'PowerShell unavailable'),
        isWindowsOverride: true,
      );

      final plan = await guard.prepare();

      expect(plan.success, isTrue);
      expect(plan.requiresElevation, isFalse);
      expect(guard.elevationState, isNull);
      expect(
        plan.logs,
        contains(
          'Elevation check unavailable; continuing until a privileged operation returns a definitive result.',
        ),
      );
    },
  );
}
