import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/split_tunnel_config.dart';
import 'package:happycat_vpnclient/services/android_vpn_controller.dart';
import 'package:happycat_vpnclient/services/vpn_core_controller.dart';

class _FakeAndroidVpnController extends AndroidVpnController {
  _FakeAndroidVpnController({
    this.running = false,
    this.prepareGranted = true,
    this.startError,
    this.startMarksRunning = true,
    this.stopSucceedsOnCall = 1,
    this.startPhase,
    this.readyAfterPolls,
  });

  bool running;
  bool prepareGranted;
  Object? startError;
  bool startMarksRunning;
  int? stopSucceedsOnCall;
  int stopCalls = 0;
  final AndroidVpnPhase? startPhase;
  final int? readyAfterPolls;
  AndroidVpnPhase? phase;
  int startupPolls = 0;

  @override
  Future<bool> prepareVpn() async => prepareGranted;

  @override
  Future<void> startVpn(
    String config, {
    String? runtime,
    String? executablePath,
    List<String>? includePackages,
    List<String>? excludePackages,
    String? routingMode,
  }) async {
    if (startError != null) {
      throw startError!;
    }
    if (startMarksRunning) {
      running = true;
    }
    phase = startPhase;
  }

  @override
  Future<void> stopVpn() async {
    stopCalls += 1;
    if (stopSucceedsOnCall != null && stopCalls >= stopSucceedsOnCall!) {
      running = false;
      phase = AndroidVpnPhase.stopped;
    }
  }

  @override
  Future<AndroidVpnStatus> getStatus() async {
    if (phase == AndroidVpnPhase.starting &&
        readyAfterPolls != null &&
        ++startupPolls >= readyAfterPolls!) {
      phase = AndroidVpnPhase.running;
      running = true;
    }
    return AndroidVpnStatus(
      phase:
          phase ??
          (running ? AndroidVpnPhase.running : AndroidVpnPhase.stopped),
      errorMessage: lastStartupError,
    );
  }

  @override
  Future<String?> getLastStartupError() async => lastStartupError;

  String? lastStartupError;
}

const _validUri =
    'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=tcp&sni=example.com#tag';

void main() {
  testWidgets('slow local startup can finish after six seconds', (
    tester,
  ) async {
    final fake = _FakeAndroidVpnController(
      startMarksRunning: false,
      startPhase: AndroidVpnPhase.starting,
      readyAfterPolls: 30,
    );
    final controller = VpnCoreController(
      androidController: fake,
      isWindowsOverride: false,
      isAndroidOverride: true,
    );
    final result = controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    await tester.pump();
    for (var i = 0; i < 35; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect((await result).success, isTrue);
    expect(fake.stopCalls, 0);
    await controller.disconnect();
  });

  testWidgets('timed-out startup is stopped instead of connecting later', (
    tester,
  ) async {
    final fake = _FakeAndroidVpnController(
      startMarksRunning: false,
      startPhase: AndroidVpnPhase.starting,
    );
    final controller = VpnCoreController(
      androidController: fake,
      isWindowsOverride: false,
      isAndroidOverride: true,
    );
    final result = controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );
    await tester.pump();
    for (var i = 0; i < 105; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect((await result).success, isFalse);
    expect(fake.stopCalls, 1);
    expect(fake.phase, AndroidVpnPhase.stopped);
  });

  test(
    'syncRuntimeState restores Android running state after app restart',
    () async {
      final fake = _FakeAndroidVpnController(running: true);
      final controller = VpnCoreController(
        androidController: fake,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );

      expect(controller.isRunning, isFalse);
      final restored = await controller.syncRuntimeState();
      expect(restored, isTrue);
      expect(controller.isRunning, isTrue);
    },
  );

  test(
    'disconnect stops Android service even when local connected flag is false',
    () async {
      final fake = _FakeAndroidVpnController(running: true);
      final controller = VpnCoreController(
        androidController: fake,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );

      expect(controller.isRunning, isFalse);
      await controller.disconnect();

      expect(fake.stopCalls, 1);
      expect(controller.isRunning, isFalse);
    },
  );

  test(
    'disconnect retries Android stop and succeeds on second attempt',
    () async {
      final fake = _FakeAndroidVpnController(
        running: true,
        stopSucceedsOnCall: 2,
      );
      final controller = VpnCoreController(
        androidController: fake,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );

      await controller.disconnect();

      expect(fake.stopCalls, 2);
      expect(controller.isRunning, isFalse);
    },
  );

  test(
    'disconnect reports active service when both stop attempts fail',
    () async {
      final fake = _FakeAndroidVpnController(
        running: true,
        stopSucceedsOnCall: null,
      );
      final controller = VpnCoreController(
        androidController: fake,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );
      final statuses = <String>[];
      final logs = <String>[];

      await controller.disconnect(onStatus: statuses.add, onLog: logs.add);

      expect(fake.stopCalls, 2);
      expect(statuses.last, contains('все еще активен'));
      expect(
        logs.any((line) => line.contains('Android stop attempt 1/2')),
        isTrue,
      );
      expect(
        logs.any((line) => line.contains('Android stop attempt 2/2')),
        isTrue,
      );
      expect(controller.isRunning, isTrue);
    },
  );

  test('connect returns failure when Android service start throws', () async {
    final fake = _FakeAndroidVpnController(
      running: false,
      startError: StateError('native start failed'),
    );
    final controller = VpnCoreController(
      androidController: fake,
      isWindowsOverride: false,
      isAndroidOverride: true,
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );

    expect(result.success, isFalse);
    expect(result.errorMessage, contains('Android VPN сервис'));
  });

  test('connect returns failure when VPN permission is denied', () async {
    final fake = _FakeAndroidVpnController(
      running: false,
      prepareGranted: false,
    );
    final controller = VpnCoreController(
      androidController: fake,
      isWindowsOverride: false,
      isAndroidOverride: true,
    );

    final result = await controller.connect(
      rawUri: _validUri,
      splitConfig: SplitTunnelConfig(mode: 'all'),
    );

    expect(result.success, isFalse);
    expect(result.errorMessage, contains('Разрешение отклонено'));
  });

  test(
    'connect returns failure when Android service did not become running',
    () async {
      final fake = _FakeAndroidVpnController(
        running: false,
        startMarksRunning: false,
      );
      final controller = VpnCoreController(
        androidController: fake,
        isWindowsOverride: false,
        isAndroidOverride: true,
      );

      final result = await controller.connect(
        rawUri: _validUri,
        splitConfig: SplitTunnelConfig(mode: 'all'),
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('не запустился'));
      expect(controller.isRunning, isFalse);
    },
  );
}
