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
  });

  bool running;
  bool prepareGranted;
  Object? startError;
  bool startMarksRunning;
  int? stopSucceedsOnCall;
  int stopCalls = 0;

  @override
  Future<bool> prepareVpn() async => prepareGranted;

  @override
  Future<void> startVpn(
    String config, {
    String? runtime,
    String? executablePath,
    List<String>? includePackages,
    List<String>? excludePackages,
  }) async {
    if (startError != null) {
      throw startError!;
    }
    if (startMarksRunning) {
      running = true;
    }
  }

  @override
  Future<void> stopVpn() async {
    stopCalls += 1;
    if (stopSucceedsOnCall != null && stopCalls >= stopSucceedsOnCall!) {
      running = false;
    }
  }

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<String?> getLastStartupError() async => lastStartupError;

  String? lastStartupError;
}

const _validUri =
    'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=tcp&sni=example.com#tag';

void main() {
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

