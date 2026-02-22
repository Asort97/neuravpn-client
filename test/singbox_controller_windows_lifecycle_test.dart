import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/split_tunnel_config.dart';
import 'package:happycat_vpnclient/services/singbox_binary_manager.dart';
import 'package:happycat_vpnclient/services/singbox_controller.dart';
import 'package:happycat_vpnclient/services/windows_tun_guard.dart';
import 'package:path/path.dart' as path;

class _FakeBinaryManager extends SingBoxBinaryManager {
  _FakeBinaryManager(this._path);

  final String? _path;

  @override
  Future<String?> resolveExecutable() async => _path;
}

class _FakeTunGuard extends WindowsTunGuard {
  _FakeTunGuard({required List<bool> waitForUp})
      : _waitForUp = List<bool>.from(waitForUp),
        super(
          isWindowsOverride: true,
          elevationChecker: () async => true,
          processRunner: (executable, arguments) async =>
              ProcessResult(1, 0, '', ''),
        );

  final List<bool> _waitForUp;
  int prepareCalls = 0;
  final List<String> cleanupCalls = <String>[];
  final List<List<String>> bulkCleanupCalls = <List<String>>[];

  @override
  Future<TunSessionPlan> prepare() async {
    prepareCalls += 1;
    final interface = 'tun-in-session-$prepareCalls';
    return TunSessionPlan(
      success: true,
      requiresElevation: false,
      inboundTag: interface,
      interfaceName: interface,
      addresses: const ['172.25.1.1/30'],
      logs: <String>['prepared $interface'],
      staleAdapters: const <String>[],
      discoveredAdapters: const <TunAdapterInfo>[],
    );
  }

  @override
  Future<TunCleanupResult> cleanupAdapter(String? interfaceName) async {
    if (interfaceName != null && interfaceName.isNotEmpty) {
      cleanupCalls.add(interfaceName);
    }
    return TunCleanupResult(
      success: true,
      removed: true,
      stillPresent: false,
      logs: <String>['cleanup $interfaceName'],
    );
  }

  @override
  Future<TunBulkCleanupResult> cleanupAdapters(List<String> adapters) async {
    bulkCleanupCalls.add(List<String>.from(adapters));
    return TunBulkCleanupResult(
      success: true,
      cleanedAdapters: List<String>.from(adapters),
      stillPresentAdapters: const <String>[],
      logs: <String>['bulk cleanup ${adapters.join(',')}'],
    );
  }

  @override
  Future<bool> waitForAdapterUp(String name, {Duration? timeout}) async {
    if (_waitForUp.isEmpty) return true;
    return _waitForUp.removeAt(0);
  }
}

class _FakeProcess implements Process {
  _FakeProcess({
    required this.pid,
    this.autoExitCode,
    this.exitDelay = Duration.zero,
    List<String> stdoutLines = const <String>[],
    List<String> stderrLines = const <String>[],
  }) {
    unawaited(
      Future<void>(() async {
        for (final line in stdoutLines) {
          _stdoutController.add(utf8.encode('$line\n'));
        }
        for (final line in stderrLines) {
          _stderrController.add(utf8.encode('$line\n'));
        }
        if (autoExitCode != null) {
          if (exitDelay > Duration.zero) {
            await Future<void>.delayed(exitDelay);
          }
          _complete(autoExitCode!);
        }
      }),
    );
  }

  @override
  final int pid;
  final int? autoExitCode;
  final Duration exitDelay;
  final Completer<int> _exitCompleter = Completer<int>();
  final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>();
  final StreamController<List<int>> _stderrController =
      StreamController<List<int>>();
  final StreamController<List<int>> _stdinController =
      StreamController<List<int>>();

  void _complete(int code) {
    if (_exitCompleter.isCompleted) return;
    _exitCompleter.complete(code);
    _stdoutController.close();
    _stderrController.close();
    _stdinController.close();
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    _complete(0);
    return true;
  }

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  IOSink get stdin => IOSink(_stdinController.sink);

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;
}

String get _validUri =>
    'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=tcp&sni=example.com#tag';

Directory get _connectionLogsDir =>
    Directory('${Directory.systemTemp.path}/neuravpn_logs');

Set<String> _existingConnectionLogPaths() {
  if (!_connectionLogsDir.existsSync()) {
    return <String>{};
  }
  return _connectionLogsDir
      .listSync()
      .whereType<File>()
      .where((file) => path.basename(file.path).startsWith('connection_'))
      .map((file) => file.path)
      .toSet();
}

void main() {
  test('auto-recover retries on recoverable TUN collision and succeeds', () async {
    final guard = _FakeTunGuard(waitForUp: <bool>[true]);
    final started = <_FakeProcess>[];
    var processIndex = 0;
    final processQueue = <_FakeProcess>[
      _FakeProcess(
        pid: 1001,
        autoExitCode: 1,
        exitDelay: const Duration(milliseconds: 30),
        stderrLines: const <String>[
          'FATAL start inbound/tun: configure tun interface: Cannot create a file when that file already exists.',
        ],
      ),
      _FakeProcess(pid: 1002),
    ];

    final statuses = <String>[];
    final controller = SingBoxController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-sing-box.exe'),
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async =>
          ProcessResult(1, 0, '', ''),
      processStarter: (executable, arguments, {environment}) async {
        final next = processQueue[processIndex++];
        started.add(next);
        return next;
      },
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
      onStatus: statuses.add,
    );

    expect(result.success, isTrue);
    expect(started.length, 2);
    expect(
      statuses.any((status) => status.contains('попытка 2/3')),
      isTrue,
    );
    expect(guard.prepareCalls, 2);

    await controller.disconnect();
  });

  test('non-recoverable startup error does not retry', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    var startCount = 0;
    final controller = SingBoxController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-sing-box.exe'),
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async =>
          ProcessResult(1, 0, '', ''),
      processStarter: (executable, arguments, {environment}) async {
        startCount += 1;
        return _FakeProcess(
          pid: 2000,
          autoExitCode: 1,
          stderrLines: const <String>['invalid config format'],
        );
      },
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );

    expect(result.success, isFalse);
    expect(startCount, 1);
  });

  test('disconnect cleans interface even when process is already null', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final controller = SingBoxController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-sing-box.exe'),
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async =>
          ProcessResult(1, 0, '', ''),
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 3000),
    );

    controller.debugSetActiveSessionForTest(
      token: 77,
      interfaceName: 'tun-in-session-77',
    );
    await controller.disconnect();

    expect(guard.cleanupCalls, contains('tun-in-session-77'));
  });

  test('old attempt cleanup does not touch current session interface', () async {
    final guard = _FakeTunGuard(waitForUp: <bool>[false, true]);
    var call = 0;
    final controller = SingBoxController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-sing-box.exe'),
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async =>
          ProcessResult(1, 0, '', ''),
      processStarter: (executable, arguments, {environment}) async {
        call += 1;
        if (call == 1) {
          return _FakeProcess(pid: 4001);
        }
        return _FakeProcess(pid: 4002);
      },
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );

    expect(result.success, isTrue);
    expect(
      guard.cleanupCalls.where((name) => name == 'tun-in-session-2').isEmpty,
      isTrue,
    );

    await controller.disconnect();
    expect(guard.cleanupCalls, contains('tun-in-session-2'));
  });

  test('connect uses info log level when developerMode is false', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final controller = SingBoxController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-sing-box.exe'),
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async =>
          ProcessResult(1, 0, '', ''),
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 5001),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
      developerMode: false,
    );

    expect(result.success, isTrue);
    final config = jsonDecode(controller.generatedConfig!);
    expect(config['log']['level'], 'info');
    await controller.disconnect();
  });

  test('connect uses debug log level when developerMode is true', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final controller = SingBoxController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-sing-box.exe'),
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async =>
          ProcessResult(1, 0, '', ''),
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 5002),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
      developerMode: true,
    );

    expect(result.success, isTrue);
    final config = jsonDecode(controller.generatedConfig!);
    expect(config['log']['level'], 'debug');
    await controller.disconnect();
  });

  test('connection log uses async buffer and throttles overflow', () async {
    final beforePaths = _existingConnectionLogPaths();
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final spamLogs = List<String>.generate(1400, (i) => 'log-line-$i');
    final controller = SingBoxController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-sing-box.exe'),
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async =>
          ProcessResult(1, 0, '', ''),
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 5003, stdoutLines: spamLogs),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
      developerMode: false,
    );

    expect(result.success, isTrue);
    await controller.disconnect();

    final afterPaths = _existingConnectionLogPaths();
    final created = afterPaths.difference(beforePaths).toList()..sort();
    expect(created, isNotEmpty);
    final text = await File(created.last).readAsString();
    expect(text.contains('connection log throttled:'), isTrue);
  });
}
