import 'dart:io';

import 'package:flutter/foundation.dart';

typedef WindowsRegistryRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class WindowsUriProtocolRegistrar {
  WindowsUriProtocolRegistrar({
    this.scheme = 'neuravpn',
    String? executablePath,
    WindowsRegistryRunner? processRunner,
  }) : executablePath = executablePath ?? Platform.resolvedExecutable,
       _processRunner = processRunner ?? _defaultProcessRunner;

  final String scheme;
  final String executablePath;
  final WindowsRegistryRunner _processRunner;

  String get _protocolKeyPath => 'HKCU\\Software\\Classes\\$scheme';

  Future<void> ensureRegistered() async {
    if (!Platform.isWindows) {
      return;
    }
    final normalizedExecutablePath = executablePath.trim();
    if (normalizedExecutablePath.isEmpty) {
      debugPrint('[uri-protocol] Skip registration: empty executable path');
      return;
    }

    final expectedCommand = '"$normalizedExecutablePath" "%1"';

    try {
      if (await _isRegistered(expectedCommand)) {
        return;
      }

      await _addStringValue(
        keyPath: _protocolKeyPath,
        valueName: null,
        value: 'URL:$scheme Protocol',
      );
      await _addStringValue(
        keyPath: _protocolKeyPath,
        valueName: 'URL Protocol',
        value: '',
      );
      await _addStringValue(
        keyPath: 'HKCU\\Software\\Classes\\$scheme\\DefaultIcon',
        valueName: null,
        value: '$normalizedExecutablePath,0',
      );
      await _addStringValue(
        keyPath: 'HKCU\\Software\\Classes\\$scheme\\shell\\open\\command',
        valueName: null,
        value: expectedCommand,
      );
      debugPrint(
        '[uri-protocol] Registered $scheme:// -> $normalizedExecutablePath',
      );
    } catch (error) {
      debugPrint('[uri-protocol] Registration failed: $error');
    }
  }

  Future<bool> _isRegistered(String expectedCommand) async {
    final commandResult = await _queryDefaultValue(
      'HKCU\\Software\\Classes\\$scheme\\shell\\open\\command',
    );
    if (commandResult.exitCode != 0) {
      return false;
    }

    final protocolResult = await _queryNamedValue(
      _protocolKeyPath,
      'URL Protocol',
    );
    if (protocolResult.exitCode != 0) {
      return false;
    }

    final stdout = '${commandResult.stdout}\n${protocolResult.stdout}';
    return stdout.contains(expectedCommand);
  }

  Future<void> _addStringValue({
    required String keyPath,
    required String? valueName,
    required String value,
  }) async {
    final arguments = <String>[
      'add',
      keyPath,
      '/t',
      'REG_SZ',
      if (valueName == null) '/ve' else ...['/v', valueName],
      '/d',
      value,
      '/f',
    ];
    final result = await _processRunner('reg', arguments);
    if (result.exitCode != 0) {
      throw ProcessException(
        'reg',
        arguments,
        '${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }
  }

  Future<ProcessResult> _queryDefaultValue(String keyPath) {
    return _processRunner('reg', ['query', keyPath, '/ve']);
  }

  Future<ProcessResult> _queryNamedValue(String keyPath, String valueName) {
    return _processRunner('reg', ['query', keyPath, '/v', valueName]);
  }

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments);
  }
}
