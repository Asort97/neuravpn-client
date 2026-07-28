import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/windows_auto_start_manager.dart';

void main() {
  const executablePath = r'C:\Program Files\neuravpn\neuravpn.exe';

  test(
    'enable creates a highest-privilege logon task and removes Run entry',
    () async {
      final host = _FakeAutoStartHost(legacyRunEntryExists: true);
      final manager = WindowsAutoStartManager(
        processRunner: host.run,
        isWindows: true,
      );

      final result = await manager.enable(executablePath);

      expect(result.success, isTrue);
      expect(result.enabled, isTrue);
      expect(host.legacyRunEntryExists, isFalse);
      expect(host.taskExecutablePath, executablePath);
      final create = host.calls.firstWhere(
        (call) =>
            call.executable == 'schtasks' && call.arguments.contains('/Create'),
      );
      expect(create.arguments, containsAll(<String>['/SC', 'ONLOGON']));
      expect(create.arguments, containsAll(<String>['/RL', 'HIGHEST']));
      expect(create.arguments, contains('/IT'));
      expect(create.arguments, containsAll(<String>['/DELAY', '0000:05']));
      expect(create.arguments, contains('"$executablePath" --autostart'));
    },
  );

  test('reconcile migrates a legacy Run entry to a scheduled task', () async {
    final host = _FakeAutoStartHost(legacyRunEntryExists: true);
    final manager = WindowsAutoStartManager(
      processRunner: host.run,
      isWindows: true,
    );

    final result = await manager.reconcile(
      desiredEnabled: false,
      executablePath: executablePath,
    );

    expect(result.success, isTrue);
    expect(result.enabled, isTrue);
    expect(host.taskExecutablePath, executablePath);
    expect(host.legacyRunEntryExists, isFalse);
  });

  test('reconcile repairs a task that points to an old executable', () async {
    final host = _FakeAutoStartHost(taskExecutablePath: r'C:\Old\neuravpn.exe');
    final manager = WindowsAutoStartManager(
      processRunner: host.run,
      isWindows: true,
    );

    final result = await manager.reconcile(
      desiredEnabled: false,
      executablePath: executablePath,
    );

    expect(result.success, isTrue);
    expect(result.enabled, isTrue);
    expect(host.taskExecutablePath, executablePath);
  });

  test('reconcile repairs a task without the autostart argument', () async {
    final host = _FakeAutoStartHost(
      taskExecutablePath: executablePath,
      taskArguments: '',
    );
    final manager = WindowsAutoStartManager(
      processRunner: host.run,
      isWindows: true,
    );

    final result = await manager.reconcile(
      desiredEnabled: true,
      executablePath: executablePath,
    );

    expect(result.success, isTrue);
    expect(result.enabled, isTrue);
    expect(host.taskArguments, '--autostart');
  });

  test('disable removes scheduled task and legacy Run entry', () async {
    final host = _FakeAutoStartHost(
      taskExecutablePath: executablePath,
      legacyRunEntryExists: true,
    );
    final manager = WindowsAutoStartManager(
      processRunner: host.run,
      isWindows: true,
    );

    final result = await manager.disable();

    expect(result.success, isTrue);
    expect(result.enabled, isFalse);
    expect(host.taskExecutablePath, isNull);
    expect(host.legacyRunEntryExists, isFalse);
  });

  test('enable keeps legacy registration when task creation fails', () async {
    final host = _FakeAutoStartHost(
      legacyRunEntryExists: true,
      taskCreateExitCode: 5,
    );
    final manager = WindowsAutoStartManager(
      processRunner: host.run,
      isWindows: true,
    );

    final result = await manager.enable(executablePath);

    expect(result.success, isFalse);
    expect(result.enabled, isFalse);
    expect(result.error, contains('Access is denied'));
    expect(host.legacyRunEntryExists, isTrue);
  });
}

class _FakeAutoStartHost {
  _FakeAutoStartHost({
    this.taskExecutablePath,
    this.taskArguments = '--autostart',
    this.legacyRunEntryExists = false,
    this.taskCreateExitCode = 0,
  });

  String? taskExecutablePath;
  String taskArguments;
  bool legacyRunEntryExists;
  final int taskCreateExitCode;
  final List<_ProcessCall> calls = <_ProcessCall>[];

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add(_ProcessCall(executable, List<String>.from(arguments)));

    if (executable == 'schtasks' && arguments.contains('/Query')) {
      final path = taskExecutablePath;
      if (path == null) return ProcessResult(1, 1, '', 'Task not found');
      return ProcessResult(
        1,
        0,
        '<Task><Actions><Exec><Command>$path</Command>'
            '<Arguments>$taskArguments</Arguments></Exec></Actions></Task>',
        '',
      );
    }

    if (executable == 'schtasks' && arguments.contains('/Create')) {
      if (taskCreateExitCode != 0) {
        return ProcessResult(1, taskCreateExitCode, '', 'Access is denied');
      }
      final taskRun = arguments[arguments.indexOf('/TR') + 1];
      taskExecutablePath = taskRun
          .replaceFirst(RegExp(r'\s+--autostart$'), '')
          .replaceAll('"', '');
      taskArguments = '--autostart';
      return ProcessResult(1, 0, 'SUCCESS', '');
    }

    if (executable == 'schtasks' && arguments.contains('/Delete')) {
      taskExecutablePath = null;
      return ProcessResult(1, 0, 'SUCCESS', '');
    }

    if (executable == 'reg' && arguments.first == 'query') {
      return legacyRunEntryExists
          ? ProcessResult(1, 0, 'neuravpn REG_SZ value', '')
          : ProcessResult(1, 1, '', 'Value not found');
    }

    if (executable == 'reg' && arguments.first == 'delete') {
      legacyRunEntryExists = false;
      return ProcessResult(1, 0, 'SUCCESS', '');
    }

    return ProcessResult(1, 0, '', '');
  }
}

class _ProcessCall {
  const _ProcessCall(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}
