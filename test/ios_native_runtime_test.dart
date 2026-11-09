import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/split_tunnel_config.dart';
import 'package:happycat_vpnclient/services/android_vpn_controller.dart';
import 'package:happycat_vpnclient/services/vpn_core_binary_manager.dart';
import 'package:happycat_vpnclient/services/vpn_core_controller.dart';

class _NoBinaryExtraction extends VpnCoreBinaryManager {
  @override
  Future<String?> resolveExecutable({String? androidRuntime}) =>
      throw StateError('iOS must not extract Android geo data or executables');
}

const _uri =
    'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=tcp&sni=example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('happycat.vpn/native');
  late List<MethodCall> calls;
  late String phase;
  late bool prepareGranted;
  late int tx;
  late int rx;
  Completer<bool>? prepareGate;

  VpnCoreController controller() => VpnCoreController(
    isWindowsOverride: false,
    isAndroidOverride: false,
    isIOSOverride: true,
    binaryManager: _NoBinaryExtraction(),
    androidController: AndroidVpnController(
      isAndroidOverride: false,
      isIOSOverride: true,
    ),
  );

  setUp(() {
    calls = [];
    phase = 'stopped';
    prepareGranted = true;
    tx = 100;
    rx = 300;
    prepareGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'prepareVpn':
              return prepareGate == null ? prepareGranted : prepareGate!.future;
            case 'startVpn':
              phase = 'running';
              return null;
            case 'stopVpn':
              phase = 'stopped';
              return null;
            case 'getVpnStatus':
              return {
                'state': phase,
                'sessionId': 'ios-session',
                'updatedAt': 1720000000000,
                'routingMode': 'all',
                'tx': tx,
                'rx': rx,
              };
            case 'getTrafficStats':
              return {'tx': tx, 'rx': rx};
            case 'getNativeVpnDebugLog':
              return 'extension running';
            case 'openVpnSettings':
              return true;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('mobile native gating supports Android and iOS only', () {
    for (final platform in ['android', 'ios', 'windows', 'other']) {
      final native = AndroidVpnController(
        isAndroidOverride: platform == 'android',
        isIOSOverride: platform == 'ios',
      );
      final core = VpnCoreController(
        isAndroidOverride: platform == 'android',
        isIOSOverride: platform == 'ios',
        isWindowsOverride: platform == 'windows',
      );
      final expected = platform == 'android' || platform == 'ios';
      expect(native.isSupported, expected);
      expect(core.isMobileNativeRuntime, expected);
    }
  });

  test(
    'iOS starts Xray through the channel with no binary or app rules',
    () async {
      final core = controller();
      final result = await core.connect(
        rawUri: _uri,
        splitConfig: SplitTunnelConfig(
          mode: 'blacklist',
          applications: ['com.example.app'],
        ),
      );
      expect(result.success, isTrue);
      expect(core.isRunning, isTrue);
      expect(core.interfaceLabel, 'iOS VPN');
      final start = calls.singleWhere((call) => call.method == 'startVpn');
      final args = start.arguments as Map;
      expect(args['runtime'], 'xray');
      expect(args.containsKey('executablePath'), isFalse);
      expect(args.containsKey('includePackages'), isFalse);
      expect(args.containsKey('excludePackages'), isFalse);
      final config = jsonDecode(args['config'] as String) as Map;
      expect(config['inbounds'][0]['port'], 10808);
      expect(config['policy']['levels']['0']['bufferSize'], 16);
      expect(calls.any((call) => call.method == 'getVpnStatus'), isTrue);
      await core.disconnect();
      expect(core.isRunning, isFalse);
      expect(calls.any((call) => call.method == 'stopVpn'), isTrue);
    },
  );

  test(
    'iOS restores extension state and reads traffic, log and network channels',
    () async {
      phase = 'running';
      final core = controller();
      expect(await core.syncRuntimeState(), isTrue);
      expect(core.androidStatus.sessionId, 'ios-session');
      final first = await core.fetchTrafficSample(useDelta: true);
      expect(first, isNotNull);
      tx += 75;
      rx += 125;
      final sample = await core.fetchTrafficSample(useDelta: true);
      expect(sample!.uplinkBps, 75);
      expect(sample.downlinkBps, 125);
      expect(await core.getAndroidNativeDebugLog(), 'extension running');
      await core.clearAndroidNativeDebugLog();
      await core.refreshAndroidNetwork();
      expect(await core.openAndroidVpnSettings(), isTrue);
      await core.startTrafficStream();
      await core.stopTrafficStream();
      expect(calls.any((call) => call.method == 'refreshNetwork'), isTrue);
      await core.forceTerminate();
      expect(phase, 'stopped');
    },
  );

  test('iOS disconnect cancels an extension still starting', () async {
    phase = 'starting';
    final core = controller();
    await core.disconnect();
    expect(phase, 'stopped');
    expect(calls.where((call) => call.method == 'stopVpn'), hasLength(1));
  });

  test('cancelling iOS permission prompt prevents a late start', () async {
    prepareGate = Completer<bool>();
    final core = controller();
    final connecting = core.connect(
      rawUri: _uri,
      splitConfig: SplitTunnelConfig(),
    );
    while (!calls.any((call) => call.method == 'prepareVpn')) {
      await Future<void>.delayed(Duration.zero);
    }
    await core.disconnect();
    prepareGate!.complete(true);
    expect((await connecting).success, isFalse);
    expect(calls.any((call) => call.method == 'startVpn'), isFalse);
  });

  test(
    'iOS returns config rejection without starting a native session',
    () async {
      final core = controller();
      final result = await core.connect(
        rawUri: _uri,
        splitConfig: SplitTunnelConfig(
          mode: 'blacklist',
          domains: ['geosite:ru'],
        ),
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('geo databases'));
      expect(calls.any((call) => call.method == 'startVpn'), isFalse);
    },
  );

  test('iOS permission rejection is returned to Flutter', () async {
    prepareGranted = false;
    final core = controller();
    final result = await core.connect(
      rawUri: _uri,
      splitConfig: SplitTunnelConfig(),
    );
    expect(result.success, isFalse);
    expect(calls.any((call) => call.method == 'startVpn'), isFalse);
  });
}
