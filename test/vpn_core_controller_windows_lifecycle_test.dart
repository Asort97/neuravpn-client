import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/split_tunnel_config.dart';
import 'package:happycat_vpnclient/services/vpn_core_binary_manager.dart';
import 'package:happycat_vpnclient/services/vpn_core_controller.dart';
import 'package:happycat_vpnclient/services/windows_dns_manager.dart';
import 'package:happycat_vpnclient/services/windows_route_manager.dart';
import 'package:happycat_vpnclient/services/windows_tun_guard.dart';
import 'package:happycat_vpnclient/services/windows_xray_core.dart';
import 'package:path/path.dart' as path;

class _FakeBinaryManager extends VpnCoreBinaryManager {
  _FakeBinaryManager(this._path);

  final String? _path;

  @override
  Future<String?> resolveExecutable({String? androidRuntime}) async => _path;
}

class _FakeTunGuard extends WindowsTunGuard {
  _FakeTunGuard({
    required List<bool> waitForUp,
    this.adapterUpDelay = Duration.zero,
    List<bool>? adapterUp,
  }) : _adapterUp = List<bool>.from(adapterUp ?? const <bool>[]),
       _waitForUp = List<bool>.from(waitForUp),
       super(
         isWindowsOverride: true,
         elevationChecker: () async => true,
         processRunner: (executable, arguments) async =>
             ProcessResult(1, 0, '', ''),
       );

  final List<bool> _waitForUp;
  final List<bool> _adapterUp;
  final Duration adapterUpDelay;
  int prepareCalls = 0;
  final List<String> cleanupCalls = <String>[];
  final List<List<String>> bulkCleanupCalls = <List<String>>[];

  @override
  bool get isElevationConfirmed => true;

  @override
  bool? get elevationState => true;

  @override
  Future<TunSessionPlan> prepare({bool detectExistingAdapters = false}) async {
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

  @override
  Future<bool> isAdapterUp(String name) async {
    if (adapterUpDelay > Duration.zero) {
      await Future<void>.delayed(adapterUpDelay);
    }
    if (_adapterUp.isEmpty) return false;
    return _adapterUp.removeAt(0);
  }
}

class _FakeWindowsRouteManager extends WindowsRouteManager {
  _FakeWindowsRouteManager({
    this.applyDelay = Duration.zero,
    this.actualTunName,
    this.cleanupGate,
  }) : super(
         processRunner: (executable, arguments) async =>
             ProcessResult(1, 0, '', ''),
         isWindowsOverride: true,
       );

  final List<String> applyCalls = <String>[];
  final List<String> cleanupCalls = <String>[];
  final Duration applyDelay;
  final String? actualTunName;
  final Completer<void>? cleanupGate;
  bool applyShouldFail = false;

  @override
  Future<WindowsRouteUplink?> discoverPrimaryUplink({
    List<String>? logs,
  }) async {
    return const WindowsRouteUplink(
      interfaceName: 'Ethernet',
      interfaceIndex: 12,
      gateway: '192.168.0.1',
      localAddress: '192.168.0.100',
    );
  }

  @override
  Future<WindowsRouteApplyResult> applyRoutes({
    required String preferredTunInterface,
    required String remoteHost,
    String? tunAddressHint,
    WindowsRouteUplink? uplink,
  }) async {
    applyCalls.add(preferredTunInterface);
    if (applyDelay > Duration.zero) {
      await Future<void>.delayed(applyDelay);
    }
    if (applyShouldFail) {
      return const WindowsRouteApplyResult(
        success: false,
        error: 'route setup failed',
      );
    }
    return WindowsRouteApplyResult(
      success: true,
      session: WindowsRouteSession(
        tunInterfaceName: actualTunName ?? preferredTunInterface,
        tunInterfaceIndex: 77,
        tunAddress: '172.19.0.1',
        uplinkInterfaceName: 'Ethernet',
        uplinkInterfaceIndex: 12,
        uplinkGateway: '192.168.0.1',
        uplinkAddress: '192.168.0.100',
        protectedPrefixes: const ['8.8.8.8'],
      ),
    );
  }

  @override
  Future<void> cleanupSession(
    WindowsRouteSession? session, {
    List<String>? logs,
  }) async {
    if (session != null) {
      cleanupCalls.add(session.tunInterfaceName);
    }
    await cleanupGate?.future;
  }

  @override
  Future<bool> cleanupStale({
    String? ownedInterfaceName,
    List<String>? logs,
  }) async => true;
}

class _FakeWindowsDnsManager extends WindowsDnsManager {
  _FakeWindowsDnsManager({
    this.recoverResult = const WindowsDnsResult(success: true),
    this.recoverGate,
    this.prepareResult = const WindowsDnsResult(success: true),
    this.applyResult = const WindowsDnsResult(success: true),
    this.restoreResult = const WindowsDnsResult(success: true),
  }) : super(
         isWindowsOverride: false,
         processRunner: (executable, arguments) async =>
             ProcessResult(1, 0, '', ''),
       );

  final WindowsDnsResult recoverResult;
  final Completer<void>? recoverGate;
  final WindowsDnsResult prepareResult;
  final WindowsDnsResult applyResult;
  final WindowsDnsResult restoreResult;
  int recoverCalls = 0;
  int prepareCalls = 0;
  int applyCalls = 0;
  int restoreCalls = 0;
  int? preparedUplink;
  int? appliedUplink;
  int? appliedTun;

  @override
  Future<WindowsDnsResult> recover() async {
    recoverCalls += 1;
    await recoverGate?.future;
    return recoverResult;
  }

  @override
  Future<WindowsDnsResult> prepare({required int uplinkInterfaceIndex}) async {
    prepareCalls += 1;
    preparedUplink = uplinkInterfaceIndex;
    return prepareResult;
  }

  @override
  Future<WindowsDnsResult> apply({
    required int uplinkInterfaceIndex,
    required int tunInterfaceIndex,
  }) async {
    applyCalls += 1;
    appliedUplink = uplinkInterfaceIndex;
    appliedTun = tunInterfaceIndex;
    return applyResult;
  }

  @override
  Future<WindowsDnsResult> restore() async {
    restoreCalls += 1;
    return restoreResult;
  }
}

class _IsolatedWindowsXrayCoreAdapter extends WindowsXrayCoreAdapter {
  @override
  int get apiPort => 65185;
}

Future<ProcessResult> _runnerWithXrayVersion(
  String executable,
  List<String> arguments,
) async {
  if (arguments.contains('version')) {
    return ProcessResult(1, 0, 'Xray 1.8.24', '');
  }
  return ProcessResult(1, 0, '', '');
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
  test(
    'parallel Windows runtime preparation performs one DNS recovery',
    () async {
      final gate = Completer<void>();
      final dnsManager = _FakeWindowsDnsManager(recoverGate: gate);
      final controller = VpnCoreController(
        tunGuard: _FakeTunGuard(waitForUp: const <bool>[]),
        windowsRouteManager: _FakeWindowsRouteManager(),
        windowsDnsManager: dnsManager,
        isWindowsOverride: true,
        isAndroidOverride: false,
      );

      final first = controller.prepareWindowsRuntime();
      final second = controller.prepareWindowsRuntime();
      await Future<void>.delayed(Duration.zero);

      expect(dnsManager.recoverCalls, 1);
      gate.complete();
      await Future.wait(<Future<void>>[first, second]);
      expect(dnsManager.recoverCalls, 1);
    },
  );

  test('full-tunnel applies and restores managed Windows DNS', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager(actualTunName: 'xray0');
    final dnsManager = _FakeWindowsDnsManager();
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      windowsDnsManager: dnsManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 9010),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );

    expect(result.success, isTrue);
    expect(dnsManager.recoverCalls, 1);
    expect(dnsManager.prepareCalls, 1);
    expect(dnsManager.preparedUplink, 12);
    expect(dnsManager.applyCalls, 1);
    expect(dnsManager.appliedUplink, 12);
    expect(dnsManager.appliedTun, 77);

    await controller.disconnect();

    expect(dnsManager.restoreCalls, greaterThanOrEqualTo(1));
  });

  test(
    'full-tunnel stays connected when managed Windows DNS is unavailable',
    () async {
      final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
      final routeManager = _FakeWindowsRouteManager(actualTunName: 'xray0');
      final dnsManager = _FakeWindowsDnsManager(
        applyResult: const WindowsDnsResult(
          success: false,
          error: 'windows_doh_not_supported',
        ),
      );
      final logs = <String>[];
      final controller = VpnCoreController(
        tunGuard: guard,
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsRouteManager: routeManager,
        windowsDnsManager: dnsManager,
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: _runnerWithXrayVersion,
        processStarter: (executable, arguments, {environment}) async =>
            _FakeProcess(pid: 9012),
      );

      final result = await controller.connect(
        rawUri: _validUri,
        splitConfig: SplitTunnelConfig(mode: 'all'),
        onLog: logs.add,
      );

      expect(result.success, isTrue);
      expect(controller.isRunning, isTrue);
      expect(dnsManager.applyCalls, 1);
      expect(dnsManager.restoreCalls, 1);
      expect(
        logs,
        contains(contains('continuing with the existing Windows resolver')),
      );

      await controller.disconnect();
    },
  );

  test(
    'full-tunnel uses system DNS when DNS preparation is unavailable',
    () async {
      final dnsManager = _FakeWindowsDnsManager(
        prepareResult: const WindowsDnsResult(
          success: false,
          error: 'dns_backup_unavailable',
        ),
      );
      final controller = VpnCoreController(
        tunGuard: _FakeTunGuard(waitForUp: const <bool>[true]),
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsRouteManager: _FakeWindowsRouteManager(actualTunName: 'xray0'),
        windowsDnsManager: dnsManager,
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: _runnerWithXrayVersion,
        processStarter: (executable, arguments, {environment}) async =>
            _FakeProcess(pid: 9013),
      );

      final result = await controller.connect(
        rawUri: _validUri,
        splitConfig: SplitTunnelConfig(mode: 'all'),
      );

      expect(result.success, isTrue);
      expect(controller.isRunning, isTrue);
      expect(dnsManager.prepareCalls, 1);
      expect(dnsManager.applyCalls, 0);

      await controller.disconnect();
    },
  );

  test('whitelist mode does not replace global Windows DNS', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager(actualTunName: 'xray0');
    final dnsManager = _FakeWindowsDnsManager();
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      windowsDnsManager: dnsManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 9011),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'whitelist'),
    );

    expect(result.success, isTrue);
    expect(dnsManager.recoverCalls, 1);
    expect(dnsManager.prepareCalls, 0);
    expect(dnsManager.applyCalls, 0);

    await controller.disconnect();
  });

  test('failed DNS cleanup is retried before the next connection', () async {
    final dnsManager = _FakeWindowsDnsManager(
      restoreResult: const WindowsDnsResult(
        success: false,
        error: 'dns_restore_failed',
      ),
    );
    var nextPid = 9020;
    final controller = VpnCoreController(
      tunGuard: _FakeTunGuard(waitForUp: const <bool>[true, true]),
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: _FakeWindowsRouteManager(actualTunName: 'xray0'),
      windowsDnsManager: dnsManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: nextPid++),
    );

    final first = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    expect(first.success, isTrue);

    await controller.disconnect();
    expect(dnsManager.restoreCalls, 1);

    final second = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    expect(second.success, isTrue);
    expect(dnsManager.recoverCalls, 2);

    await controller.disconnect();
  });

  test('reconnect waits for cleanup of the previous Windows session', () async {
    final cleanupGate = Completer<void>();
    final routeManager = _FakeWindowsRouteManager(
      actualTunName: 'xray0',
      cleanupGate: cleanupGate,
    );
    final processes = <_FakeProcess>[];
    final controller = VpnCoreController(
      tunGuard: _FakeTunGuard(waitForUp: const <bool>[true, true]),
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      windowsDnsManager: _FakeWindowsDnsManager(),
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
      processStarter: (executable, arguments, {environment}) async {
        final process = _FakeProcess(pid: 9020 + processes.length);
        processes.add(process);
        return process;
      },
    );

    final first = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    expect(first.success, isTrue);
    expect(processes, hasLength(1));

    processes.single.kill();
    for (var i = 0; i < 50 && routeManager.cleanupCalls.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(routeManager.cleanupCalls, isNotEmpty);

    final reconnect = controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(processes, hasLength(1));

    cleanupGate.complete();
    final second = await reconnect;
    expect(second.success, isTrue);
    expect(processes, hasLength(2));

    await controller.disconnect();
  });

  test(
    'auto-recover retries on recoverable TUN collision and succeeds',
    () async {
      final guard = _FakeTunGuard(
        waitForUp: <bool>[true],
        adapterUp: <bool>[false, true],
      );
      final routeManager = _FakeWindowsRouteManager();
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
      final controller = VpnCoreController(
        tunGuard: guard,
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsCoreAdapter: _IsolatedWindowsXrayCoreAdapter(),
        windowsRouteManager: routeManager,
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: _runnerWithXrayVersion,
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
      expect(statuses.any((status) => status.contains('попытка 2/3')), isTrue);
      expect(guard.prepareCalls, 2);

      await controller.disconnect();
    },
  );

  test('non-recoverable startup error does not retry', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager();
    var startCount = 0;
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
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

  test(
    'access denied from Xray is not mislabeled after elevation is confirmed',
    () async {
      final statuses = <String>[];
      final controller = VpnCoreController(
        tunGuard: _FakeTunGuard(waitForUp: const <bool>[true]),
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsRouteManager: _FakeWindowsRouteManager(),
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: _runnerWithXrayVersion,
        processStarter: (executable, arguments, {environment}) async =>
            _FakeProcess(
              pid: 2001,
              autoExitCode: 1,
              stderrLines: const <String>[
                'driver open failed: Access is denied',
              ],
            ),
      );

      final result = await controller.connect(
        rawUri: _validUri,
        splitConfig: SplitTunnelConfig(mode: 'all'),
        onStatus: statuses.add,
      );

      expect(result.success, isFalse);
      expect(result.requiresAdmin, isFalse);
      expect(
        statuses.any((status) => status.contains('администратора')),
        isFalse,
      );
    },
  );

  test(
    'DNS access denied is not mislabeled after elevation is confirmed',
    () async {
      final controller = VpnCoreController(
        tunGuard: _FakeTunGuard(waitForUp: const <bool>[]),
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsRouteManager: _FakeWindowsRouteManager(),
        windowsDnsManager: _FakeWindowsDnsManager(
          recoverResult: const WindowsDnsResult(
            success: false,
            error: 'Access is denied',
          ),
        ),
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: _runnerWithXrayVersion,
      );

      final result = await controller.connect(
        rawUri: _validUri,
        splitConfig: SplitTunnelConfig(mode: 'all'),
      );

      expect(result.success, isFalse);
      expect(result.requiresAdmin, isFalse);
      expect(result.errorMessage, contains('Access is denied'));
    },
  );

  test('disconnect cancels an in-flight Windows connection', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager(
      applyDelay: const Duration(milliseconds: 80),
    );
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 2500),
    );

    final connecting = controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await controller.disconnect();
    final result = await connecting;

    expect(result.success, isFalse);
    expect(result.errorMessage, 'Подключение отменено');
    expect(controller.isRunning, isFalse);
  });

  test(
    'rejects an invalid Xray configuration before process startup',
    () async {
      final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
      final routeManager = _FakeWindowsRouteManager();
      var startCalls = 0;
      final controller = VpnCoreController(
        tunGuard: guard,
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsRouteManager: routeManager,
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: (executable, arguments) async {
          if (arguments.contains('version')) {
            return ProcessResult(1, 0, 'Xray 1.8.24', '');
          }
          if (arguments.length >= 2 &&
              arguments[0] == 'run' &&
              arguments[1] == '-test') {
            return ProcessResult(1, 1, '', 'invalid xhttp settings');
          }
          return ProcessResult(1, 0, '', '');
        },
        processStarter: (executable, arguments, {environment}) async {
          startCalls += 1;
          return _FakeProcess(pid: 2600);
        },
      );

      final result = await controller.connect(
        rawUri: _validUri,
        splitConfig: SplitTunnelConfig(mode: 'all'),
      );

      expect(result.success, isFalse);
      expect(
        result.errorMessage,
        contains('Конфигурация Xray не прошла проверку'),
      );
      expect(startCalls, 0);
    },
  );

  test('uses the runtime Xray adapter name for routes and cleanup', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager(actualTunName: 'xray0');
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 2700),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );

    expect(result.success, isTrue);
    expect(controller.interfaceLabel, 'xray0');

    await controller.disconnect();

    expect(routeManager.cleanupCalls, contains('xray0'));
    expect(guard.cleanupCalls, isNot(contains('xray0')));
  });

  test(
    'disconnect cleans interface even when process is already null',
    () async {
      final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
      final routeManager = _FakeWindowsRouteManager();
      final controller = VpnCoreController(
        tunGuard: guard,
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsRouteManager: routeManager,
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: _runnerWithXrayVersion,
        processStarter: (executable, arguments, {environment}) async =>
            _FakeProcess(pid: 3000),
      );

      controller.debugSetActiveSessionForTest(
        token: 77,
        interfaceName: 'tun-in-session-77',
      );
      await controller.disconnect();

      expect(guard.cleanupCalls, contains('tun-in-session-77'));
    },
  );

  test(
    'old attempt cleanup does not touch current session interface',
    () async {
      final guard = _FakeTunGuard(
        waitForUp: <bool>[...List<bool>.filled(100, false), true],
      );
      final routeManager = _FakeWindowsRouteManager();
      var call = 0;
      final controller = VpnCoreController(
        tunGuard: guard,
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsRouteManager: routeManager,
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: _runnerWithXrayVersion,
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
      final activeInterface = controller.interfaceLabel;
      expect(
        guard.cleanupCalls.where((name) => name == activeInterface).isEmpty,
        isTrue,
      );

      await controller.disconnect();
      expect(guard.cleanupCalls, contains(activeInterface));
    },
  );

  test(
    'connect succeeds when xray reports tun up even if adapter name probe fails',
    () async {
      final guard = _FakeTunGuard(waitForUp: List<bool>.filled(32, false));
      final routeManager = _FakeWindowsRouteManager();
      final controller = VpnCoreController(
        tunGuard: guard,
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsRouteManager: routeManager,
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: (executable, arguments) async {
          if (arguments.contains('version')) {
            return ProcessResult(1, 0, 'Xray 1.8.24', '');
          }
          if (arguments.length >= 2 &&
              arguments[0] == 'api' &&
              arguments[1] == 'statsquery') {
            return ProcessResult(1, 0, 'ok', '');
          }
          return ProcessResult(1, 0, '', '');
        },
        processStarter: (executable, arguments, {environment}) async =>
            _FakeProcess(
              pid: 4501,
              stderrLines: const <String>[
                '2026/03/17 00:30:17.719981 [Info] proxy/tun: xray0 created',
                '2026/03/17 00:30:17.719981 [Info] proxy/tun: xray0 up',
              ],
            ),
      );

      final result = await controller.connect(
        rawUri: _validUri,
        splitConfig: SplitTunnelConfig(mode: 'all'),
      );

      expect(result.success, isTrue);
      expect(controller.isRunning, isTrue);
      await controller.disconnect();
    },
  );

  test('slow adapter probe does not hide xray tun-ready signal', () async {
    final guard = _FakeTunGuard(
      waitForUp: const <bool>[],
      adapterUp: const <bool>[false],
      adapterUpDelay: const Duration(milliseconds: 3300),
    );
    final routeManager = _FakeWindowsRouteManager();
    var startCount = 0;
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
      processStarter: (executable, arguments, {environment}) async {
        startCount += 1;
        return _FakeProcess(
          pid: 4502,
          stdoutLines: const <String>[
            '2026/06/30 13:58:10.344856 [Info] proxy/tun: xray0 created',
            '2026/06/30 13:58:10.344856 [Info] proxy/tun: xray0 up',
          ],
          stderrLines: const <String>[
            '2026/06/30 13:58:10.416435 Removed orphaned adapter "xray0 1"',
          ],
        );
      },
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );

    expect(result.success, isTrue);
    expect(startCount, 1);
    expect(guard.prepareCalls, 1);
    await controller.disconnect();
  });

  test('connect uses info log level when developerMode is false', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager();
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
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
    expect(config['log']['loglevel'], 'info');
    await controller.disconnect();
  });

  test('connect uses debug log level when developerMode is true', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager();
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
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
    expect(config['log']['loglevel'], 'debug');
    await controller.disconnect();
  });

  test('connection log uses async buffer and throttles overflow', () async {
    final beforePaths = _existingConnectionLogPaths();
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager();
    final spamLogs = List<String>.generate(1400, (i) => 'log-line-$i');
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: _runnerWithXrayVersion,
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 5003, stdoutLines: spamLogs),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
      developerMode: true,
    );

    expect(result.success, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await controller.disconnect();

    final afterPaths = _existingConnectionLogPaths();
    final candidates = afterPaths.difference(beforePaths).toList()..sort();
    final targetPath = candidates.isNotEmpty
        ? candidates.last
        : (_connectionLogsDir
                  .listSync()
                  .whereType<File>()
                  .where(
                    (file) =>
                        path.basename(file.path).startsWith('connection_'),
                  )
                  .toList()
                ..sort(
                  (a, b) =>
                      a.statSync().modified.compareTo(b.statSync().modified),
                ))
              .last
              .path;
    final text = await File(targetPath).readAsString();
    expect(text.contains('connection log throttled:'), isTrue);
  });

  test('hot reload applies routing rules without reconnect', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager();
    var startCount = 0;
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async {
        if (arguments.contains('version')) {
          return ProcessResult(1, 0, 'Xray 1.8.24', '');
        }
        if (arguments.length >= 2 &&
            arguments[0] == 'api' &&
            arguments[1] == 'adrules') {
          return ProcessResult(1, 0, 'ok', '');
        }
        return ProcessResult(1, 0, '', '');
      },
      processStarter: (executable, arguments, {environment}) async {
        startCount += 1;
        return _FakeProcess(pid: 6101);
      },
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    expect(result.success, isTrue);

    final updated = await controller.hotReloadWindowsRules(
      splitConfig: SplitTunnelConfig(
        mode: 'whitelist',
        domains: ['example.com'],
      ),
    );
    expect(updated, isTrue);
    expect(startCount, 1);
    await controller.disconnect();
  });

  test('hot reload returns false when routing update command fails', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager();
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async {
        if (arguments.contains('version')) {
          return ProcessResult(1, 0, 'Xray 1.8.24', '');
        }
        if (arguments.length >= 2 &&
            arguments[0] == 'api' &&
            arguments[1] == 'adrules') {
          return ProcessResult(1, 1, '', 'unsupported');
        }
        return ProcessResult(1, 0, '', '');
      },
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 6102),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    expect(result.success, isTrue);
    final updated = await controller.hotReloadWindowsRules(
      splitConfig: SplitTunnelConfig(
        mode: 'blacklist',
        domains: ['example.com'],
      ),
    );
    expect(updated, isFalse);
    await controller.disconnect();
  });

  test('fetchTrafficBps parses xray api statsquery output', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager();
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async {
        if (arguments.contains('version')) {
          return ProcessResult(1, 0, 'Xray 1.8.24', '');
        }
        if (arguments.length >= 2 &&
            arguments[0] == 'api' &&
            arguments[1] == 'statsquery') {
          return ProcessResult(
            1,
            0,
            'name: "outbound>>>tag>>>traffic>>>downlink"\nvalue: 2048\n'
                'name: "outbound>>>tag>>>traffic>>>uplink"\nvalue: 512\n',
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 6103),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    expect(result.success, isTrue);

    final sample = await controller.fetchTrafficBps();
    expect(sample, 2560);
    await controller.disconnect();
  });

  test('fetchTrafficBps parses quoted statsquery values', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager();
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async {
        if (arguments.contains('version')) {
          return ProcessResult(1, 0, 'Xray 1.8.24', '');
        }
        if (arguments.length >= 2 &&
            arguments[0] == 'api' &&
            arguments[1] == 'statsquery') {
          return ProcessResult(
            1,
            0,
            'name: "outbound>>>tag>>>traffic>>>downlink"\nvalue: "4096"\n'
                'name: "outbound>>>tag>>>traffic>>>uplink"\nvalue: "1024"\n',
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 6104),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    expect(result.success, isTrue);

    final sample = await controller.fetchTrafficBps();
    expect(sample, 5120);
    await controller.disconnect();
  });

  test(
    'fetchTrafficBps falls back to inbound counters when outbound is zero',
    () async {
      final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
      final routeManager = _FakeWindowsRouteManager();
      final controller = VpnCoreController(
        tunGuard: guard,
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsRouteManager: routeManager,
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: (executable, arguments) async {
          if (arguments.contains('version')) {
            return ProcessResult(1, 0, 'Xray 1.8.24', '');
          }
          if (arguments.length >= 2 &&
              arguments[0] == 'api' &&
              arguments[1] == 'statsquery') {
            return ProcessResult(
              1,
              0,
              'name: "outbound>>>tag>>>traffic>>>downlink"\nvalue: 0\n'
                  'name: "outbound>>>tag>>>traffic>>>uplink"\nvalue: 0\n'
                  'name: "inbound>>>tun-in-session-1>>>traffic>>>downlink"\nvalue: 8192\n'
                  'name: "inbound>>>tun-in-session-1>>>traffic>>>uplink"\nvalue: 2048\n',
              '',
            );
          }
          return ProcessResult(1, 0, '', '');
        },
        processStarter: (executable, arguments, {environment}) async =>
            _FakeProcess(pid: 6105),
      );

      final result = await controller.connect(
        rawUri: _validUri,
        splitConfig: SplitTunnelConfig(mode: 'all'),
      );
      expect(result.success, isTrue);

      final sample = await controller.fetchTrafficBps();
      expect(sample, 10240);
      await controller.disconnect();
    },
  );

  test(
    'fetchTrafficSample useDelta handles counter resets without dropping to zero',
    () async {
      final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
      final routeManager = _FakeWindowsRouteManager();
      int statsQueryCalls = 0;
      final controller = VpnCoreController(
        tunGuard: guard,
        binaryManager: _FakeBinaryManager('fake-xray.exe'),
        windowsRouteManager: routeManager,
        isWindowsOverride: true,
        isAndroidOverride: false,
        processRunner: (executable, arguments) async {
          if (arguments.contains('version')) {
            return ProcessResult(1, 0, 'Xray 1.8.24', '');
          }
          if (arguments.length >= 2 &&
              arguments[0] == 'api' &&
              arguments[1] == 'statsquery') {
            statsQueryCalls += 1;
            if (statsQueryCalls == 1) {
              return ProcessResult(
                1,
                0,
                'name: "outbound>>>tag>>>traffic>>>downlink"\nvalue: 1000\n'
                    'name: "outbound>>>tag>>>traffic>>>uplink"\nvalue: 500\n',
                '',
              );
            }
            return ProcessResult(
              1,
              0,
              'name: "outbound>>>tag>>>traffic>>>downlink"\nvalue: 100\n'
                  'name: "outbound>>>tag>>>traffic>>>uplink"\nvalue: 50\n',
              '',
            );
          }
          return ProcessResult(1, 0, '', '');
        },
        processStarter: (executable, arguments, {environment}) async =>
            _FakeProcess(pid: 6106),
      );

      final result = await controller.connect(
        rawUri: _validUri,
        splitConfig: SplitTunnelConfig(mode: 'all'),
      );
      expect(result.success, isTrue);

      final sample1 = await controller.fetchTrafficSample(useDelta: true);
      final sample2 = await controller.fetchTrafficSample(useDelta: true);
      expect(sample1, isNotNull);
      expect(sample2, isNotNull);
      expect(sample1!.totalBps, 1500);
      expect(sample2!.totalBps, 150);

      await controller.disconnect();
    },
  );

  test('fetchTrafficBps uses direct api stats counters when available', () async {
    final guard = _FakeTunGuard(waitForUp: const <bool>[true]);
    final routeManager = _FakeWindowsRouteManager();
    final controller = VpnCoreController(
      tunGuard: guard,
      binaryManager: _FakeBinaryManager('fake-xray.exe'),
      windowsRouteManager: routeManager,
      isWindowsOverride: true,
      isAndroidOverride: false,
      processRunner: (executable, arguments) async {
        if (arguments.contains('version')) {
          return ProcessResult(1, 0, 'Xray 1.8.24', '');
        }
        if (arguments.length >= 2 &&
            arguments[0] == 'api' &&
            arguments[1] == 'stats') {
          final statArg = arguments.firstWhere(
            (arg) => arg.startsWith('--name='),
            orElse: () => '',
          );
          if (statArg.contains(
            'inbound>>>tun-in-session-1>>>traffic>>>downlink',
          )) {
            return ProcessResult(
              1,
              0,
              'name: "inbound>>>tun-in-session-1>>>traffic>>>downlink"\nvalue: 12288\n',
              '',
            );
          }
          if (statArg.contains(
            'inbound>>>tun-in-session-1>>>traffic>>>uplink',
          )) {
            return ProcessResult(
              1,
              0,
              'name: "inbound>>>tun-in-session-1>>>traffic>>>uplink"\nvalue: 3072\n',
              '',
            );
          }
          return ProcessResult(1, 0, '', '');
        }
        if (arguments.length >= 2 &&
            arguments[0] == 'api' &&
            arguments[1] == 'statsquery') {
          return ProcessResult(1, 0, '', '');
        }
        return ProcessResult(1, 0, '', '');
      },
      processStarter: (executable, arguments, {environment}) async =>
          _FakeProcess(pid: 6107),
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    expect(result.success, isTrue);

    final sample = await controller.fetchTrafficBps();
    expect(sample, 15360);
    await controller.disconnect();
  });
}
