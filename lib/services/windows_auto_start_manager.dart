import 'dart:io';

typedef WindowsAutoStartProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class WindowsAutoStartResult {
  const WindowsAutoStartResult({
    required this.success,
    required this.enabled,
    this.logs = const <String>[],
    this.error,
  });

  final bool success;
  final bool enabled;
  final List<String> logs;
  final String? error;
}

class WindowsAutoStartStatus {
  const WindowsAutoStartStatus({
    required this.taskExists,
    required this.taskMatchesExecutable,
    required this.legacyRunEntryExists,
  });

  final bool taskExists;
  final bool taskMatchesExecutable;
  final bool legacyRunEntryExists;

  bool get hasAnyRegistration => taskExists || legacyRunEntryExists;
}

class WindowsAutoStartManager {
  WindowsAutoStartManager({
    this.taskName = 'neuravpn',
    WindowsAutoStartProcessRunner? processRunner,
    bool? isWindows,
  }) : _processRunner = processRunner ?? _defaultProcessRunner,
       _isWindows = isWindows ?? Platform.isWindows;

  static const String legacyRunKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String legacyValueName = 'neuravpn';

  final String taskName;
  final WindowsAutoStartProcessRunner _processRunner;
  final bool _isWindows;

  Future<WindowsAutoStartResult> enable(String executablePath) async {
    final logs = <String>[];
    final normalizedPath = executablePath.trim();
    if (!_isWindows) {
      return const WindowsAutoStartResult(success: true, enabled: false);
    }
    if (normalizedPath.isEmpty) {
      return const WindowsAutoStartResult(
        success: false,
        enabled: false,
        error: 'Executable path is empty',
      );
    }

    final taskCommand = '"$normalizedPath" --autostart';
    final createArguments = <String>[
      '/Create',
      '/TN',
      taskName,
      '/SC',
      'ONLOGON',
      '/DELAY',
      '0000:05',
      '/TR',
      taskCommand,
      '/RL',
      'HIGHEST',
      '/IT',
      '/F',
    ];
    final createResult = await _processRunner('schtasks', createArguments);
    if (createResult.exitCode != 0) {
      final error = _resultDetails(createResult);
      logs.add('[autostart] Scheduled task creation failed: $error');
      return WindowsAutoStartResult(
        success: false,
        enabled: false,
        logs: logs,
        error: error,
      );
    }
    logs.add('[autostart] Scheduled task "$taskName" created.');

    final status = await queryStatus(normalizedPath);
    if (!status.taskExists || !status.taskMatchesExecutable) {
      const error = 'Scheduled task verification failed';
      logs.add('[autostart] $error.');
      return WindowsAutoStartResult(
        success: false,
        enabled: false,
        logs: logs,
        error: error,
      );
    }

    final legacyDelete = await _deleteLegacyRunEntry();
    if (legacyDelete.exitCode == 0) {
      logs.add('[autostart] Removed legacy Run registry entry.');
    }
    return WindowsAutoStartResult(success: true, enabled: true, logs: logs);
  }

  Future<WindowsAutoStartResult> disable() async {
    final logs = <String>[];
    if (!_isWindows) {
      return const WindowsAutoStartResult(success: true, enabled: false);
    }

    final taskQuery = await _queryTask();
    if (taskQuery.exitCode == 0) {
      final deleteResult = await _processRunner('schtasks', <String>[
        '/Delete',
        '/TN',
        taskName,
        '/F',
      ]);
      if (deleteResult.exitCode != 0) {
        final error = _resultDetails(deleteResult);
        logs.add('[autostart] Scheduled task deletion failed: $error');
        return WindowsAutoStartResult(
          success: false,
          enabled: true,
          logs: logs,
          error: error,
        );
      }
      logs.add('[autostart] Scheduled task "$taskName" deleted.');
    }

    final legacyQuery = await _queryLegacyRunEntry();
    if (legacyQuery.exitCode == 0) {
      final deleteResult = await _deleteLegacyRunEntry();
      if (deleteResult.exitCode != 0) {
        final error = _resultDetails(deleteResult);
        logs.add('[autostart] Legacy Run entry deletion failed: $error');
        return WindowsAutoStartResult(
          success: false,
          enabled: true,
          logs: logs,
          error: error,
        );
      }
      logs.add('[autostart] Legacy Run registry entry deleted.');
    }

    final status = await queryStatus('');
    if (status.hasAnyRegistration) {
      const error = 'Autostart registration is still present';
      logs.add('[autostart] $error.');
      return WindowsAutoStartResult(
        success: false,
        enabled: true,
        logs: logs,
        error: error,
      );
    }

    return WindowsAutoStartResult(success: true, enabled: false, logs: logs);
  }

  Future<WindowsAutoStartResult> reconcile({
    required bool desiredEnabled,
    required String executablePath,
  }) async {
    if (!_isWindows) {
      return const WindowsAutoStartResult(success: true, enabled: false);
    }

    final status = await queryStatus(executablePath);
    final shouldEnable = desiredEnabled || status.hasAnyRegistration;
    if (!shouldEnable) {
      return const WindowsAutoStartResult(success: true, enabled: false);
    }

    if (status.taskExists &&
        status.taskMatchesExecutable &&
        !status.legacyRunEntryExists) {
      return const WindowsAutoStartResult(success: true, enabled: true);
    }

    return enable(executablePath);
  }

  Future<WindowsAutoStartStatus> queryStatus(String executablePath) async {
    if (!_isWindows) {
      return const WindowsAutoStartStatus(
        taskExists: false,
        taskMatchesExecutable: false,
        legacyRunEntryExists: false,
      );
    }

    final taskResult = await _queryTask();
    final taskExists = taskResult.exitCode == 0;
    final expectedPath = _normalizePath(executablePath);
    final taskPath = taskExists
        ? _extractTaskExecutable(taskResult.stdout.toString())
        : '';
    final taskArguments = taskExists
        ? _extractTaskArguments(taskResult.stdout.toString())
        : '';
    final taskMatches =
        taskExists &&
        expectedPath.isNotEmpty &&
        _normalizePath(taskPath) == expectedPath &&
        taskArguments.split(RegExp(r'\s+')).contains('--autostart');
    final legacyResult = await _queryLegacyRunEntry();

    return WindowsAutoStartStatus(
      taskExists: taskExists,
      taskMatchesExecutable: taskMatches,
      legacyRunEntryExists: legacyResult.exitCode == 0,
    );
  }

  Future<ProcessResult> _queryTask() {
    return _processRunner('schtasks', <String>[
      '/Query',
      '/TN',
      taskName,
      '/XML',
    ]);
  }

  Future<ProcessResult> _queryLegacyRunEntry() {
    return _processRunner('reg', <String>[
      'query',
      legacyRunKey,
      '/v',
      legacyValueName,
    ]);
  }

  Future<ProcessResult> _deleteLegacyRunEntry() {
    return _processRunner('reg', <String>[
      'delete',
      legacyRunKey,
      '/v',
      legacyValueName,
      '/f',
    ]);
  }

  String _extractTaskExecutable(String xml) {
    final match = RegExp(
      r'<Command>(.*?)</Command>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(xml);
    return _decodeXml(match?.group(1) ?? '');
  }

  String _extractTaskArguments(String xml) {
    final match = RegExp(
      r'<Arguments>(.*?)</Arguments>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(xml);
    return _decodeXml(match?.group(1) ?? '');
  }

  String _decodeXml(String value) {
    return value
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .trim();
  }

  String _normalizePath(String value) {
    return value.trim().replaceAll('"', '').replaceAll('/', '\\').toLowerCase();
  }

  String _resultDetails(ProcessResult result) {
    final stderr = result.stderr.toString().trim();
    final stdout = result.stdout.toString().trim();
    if (stderr.isNotEmpty) return stderr;
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
