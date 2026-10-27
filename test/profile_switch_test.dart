import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:happycat_vpnclient/main.dart';
import 'package:happycat_vpnclient/models/split_tunnel_config.dart';
import 'package:happycat_vpnclient/models/vpn_profile.dart';
import 'package:happycat_vpnclient/models/vpn_subscription.dart';
import 'package:happycat_vpnclient/services/subscription_repository.dart';
import 'package:happycat_vpnclient/services/android_vpn_controller.dart';
import 'package:happycat_vpnclient/services/dpi_evasion_config.dart';
import 'package:happycat_vpnclient/services/smart_route_engine.dart';
import 'package:happycat_vpnclient/services/vpn_core_controller.dart';
import 'package:happycat_vpnclient/widgets/profile_list_view.dart';

final profiles = List.generate(
  3,
  (index) => VpnProfile(
    name: 'Route ${index + 1}',
    uri:
        'vless://11111111-1111-1111-1111-111111111111@'
        'server${index + 1}.example.com:443?security=tls&type=tcp#Route${index + 1}',
  ),
);

class _LocalHttpOverrides extends HttpOverrides {
  final clients = <HttpClient>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context)..idleTimeout = Duration.zero;
    clients.add(client);
    return client;
  }
}

class FakeVpnCore extends VpnCoreController {
  FakeVpnCore() : super(isWindowsOverride: false, isAndroidOverride: false);

  AndroidVpnPhase phase = AndroidVpnPhase.stopped;
  AndroidVpnPhase? phaseOnSync;
  Completer<void>? syncGate;
  Completer<void>? stopGate;
  Completer<void>? startGate;
  AndroidVpnPhase stopResult = AndroidVpnPhase.stopped;
  bool failStart = false;
  bool throwOnStop = false;
  int operation = 0;
  final calls = <String>[];
  final startedUris = <String>[];
  final developerModes = <bool>[];

  @override
  bool get isRunning => phase == AndroidVpnPhase.running;

  @override
  AndroidVpnStatus get androidStatus => AndroidVpnStatus(phase: phase);

  @override
  Future<bool> syncRuntimeState() async {
    calls.add('sync');
    await syncGate?.future;
    phase = phaseOnSync ?? phase;
    return isRunning;
  }

  @override
  Future<void> disconnect({
    void Function(String)? onStatus,
    void Function(String)? onLog,
  }) async {
    operation++;
    calls.add('stop');
    if (throwOnStop) throw StateError('stop failed');
    phase = AndroidVpnPhase.stopping;
    await stopGate?.future;
    phase = stopResult;
    calls.add('stop-complete');
  }

  @override
  Future<VpnCoreStartResult> connect({
    required String rawUri,
    required SplitTunnelConfig splitConfig,
    bool developerMode = false,
    SmartRouteEngine? smartRouteEngine,
    DpiEvasionConfig dpiEvasionConfig = DpiEvasionConfig.balanced,
    void Function(String)? onStatus,
    void Function(String)? onLog,
  }) async {
    final token = ++operation;
    calls.add('start');
    startedUris.add(rawUri);
    developerModes.add(developerMode);
    phase = AndroidVpnPhase.starting;
    await startGate?.future;
    if (token != operation) return VpnCoreStartResult.failure('Cancelled');
    phase = failStart ? AndroidVpnPhase.error : AndroidVpnPhase.running;
    return failStart
        ? VpnCoreStartResult.failure('Test connection failed')
        : VpnCoreStartResult.success();
  }

  @override
  Future<void> startTrafficStream() async {}

  @override
  Future<void> stopTrafficStream() async {}

  @override
  Future<void> dispose() async {}
}

ProfileListView profileList(WidgetTester tester) =>
    tester.widget<ProfileListView>(find.byType(ProfileListView).first);

Future<void> pumpApp(
  WidgetTester tester,
  FakeVpnCore core, {
  List<String> launchArgs = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    MaterialApp(
      home: VlessHomePage(
        vpnCoreController: core,
        initialLaunchArgs: launchArgs,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 800));
  await tester.pump(const Duration(milliseconds: 100));
  expect(profileList(tester).selectedProfile?.uri, profiles.first.uri);
  core.calls.clear();
}

void main() {
  setUp(() {
    debugForceMobileShell = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('happycat.vpn/dpi'),
          (call) async => null,
        );
    SharedPreferences.setMockInitialValues({
      'vpn_profiles': VpnProfile.listToJsonString(profiles),
      'vpn_profile_selected_uri': profiles.first.uri,
      'vpn_profile_selected': profiles.first.name,
      'has_added_key': true,
      'smart_routing_enabled': false,
    });
  });

  tearDown(() {
    debugForceMobileShell = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('happycat.vpn/dpi'),
          null,
        );
  });

  testWidgets(
    'standalone HY2 import preserves subscriptions, manual keys and selection after restart',
    (tester) async {
      final repository = SubscriptionRepository();
      for (var i = 0; i < 2; i++) {
        await repository.addSubscription(
          VpnSubscription(
            name: 'Subscription $i',
            url: 'https://example.com/sub/$i',
            profiles: [profiles[i].uri],
          ),
        );
      }
      final prefs = await SharedPreferences.getInstance();
      final savedSubscriptions = List<String>.from(
        prefs.getStringList('vpn_subscriptions_list')!,
      );
      const uri = 'hy2://password@example.com:443?sni=example.com#Hysteria';
      final core = FakeVpnCore();
      await pumpApp(tester, core, launchArgs: [uri]);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(prefs.getStringList('vpn_subscriptions_list'), savedSubscriptions);
      expect(profileList(tester).profiles.map((p) => p.uri), [
        ...profiles.map((p) => p.uri),
        uri,
      ]);
      expect(profileList(tester).selectedProfile?.uri, profiles.first.uri);
      expect(core.startedUris, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await pumpApp(tester, FakeVpnCore());
      expect(profileList(tester).profiles.map((p) => p.uri), [
        ...profiles.map((p) => p.uri),
        uri,
      ]);
      expect(prefs.getStringList('vpn_subscriptions_list'), savedSubscriptions);
    },
  );

  testWidgets(
    'subscription import preserves standalone keys and active selection',
    (tester) async {
      final server = await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      );
      server!.listen((request) {
        request.response.write('hy2://password@example.net:443#Subscription');
        request.response.close();
      });
      final overrides = _LocalHttpOverrides();
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          final core = FakeVpnCore();
          final url = 'http://127.0.0.1:${server.port}/sub';
          await pumpApp(
            tester,
            core,
            launchArgs: ['neuravpn://import?v=${Uri.encodeComponent(url)}'],
          );
          for (var i = 0; i < 20; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump(const Duration(milliseconds: 100));
            if ((await SubscriptionRepository().getAllSubscriptions())
                .isNotEmpty)
              break;
          }
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 3));
          await tester.pumpAndSettle();
          // Let the startup subscription refresh finish its real loopback IO.
          for (var i = 0; i < 10; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            (await SubscriptionRepository().getAllSubscriptions())
                .single
                .profiles,
            ['hy2://password@example.net:443#Subscription'],
          );
          expect(
            profileList(tester).profiles.map((p) => p.uri),
            profiles.map((p) => p.uri),
          );
          expect(profileList(tester).selectedProfile?.uri, profiles.first.uri);
          expect(core.startedUris, isEmpty);
          final prefs = await SharedPreferences.getInstance();
          expect(
            VpnProfile.listFromJsonString(
              prefs.getString('vpn_profiles')!,
            ).map((p) => p.uri),
            profiles.map((p) => p.uri),
          );
        }, overrides);
      } finally {
        await tester.pumpWidget(const SizedBox());
        for (final client in overrides.clients) {
          client.close(force: true);
        }
        await tester.runAsync(() => server.close(force: true));
        await tester.pump(const Duration(seconds: 31));
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'legacy mobile auto-connect and developer preferences are ignored',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('auto_connect_on_startup', true);
      await prefs.setBool('developer_mode', true);
      final core = FakeVpnCore();
      await pumpApp(tester, core);
      expect(core.startedUris, isEmpty);
      await tester.tap(find.byKey(const ValueKey('main-connect-button')));
      await tester.pumpAndSettle();
      expect(core.startedUris, [profiles.first.uri]);
      expect(core.developerModes, [false]);
      // The Windows preferences are not deleted by mobile presentation tests.
      expect(prefs.getBool('auto_connect_on_startup'), isTrue);
      expect(prefs.getBool('developer_mode'), isTrue);
    },
  );

  testWidgets('disconnected selection never starts VPN', (tester) async {
    final core = FakeVpnCore();
    await pumpApp(tester, core);
    profileList(tester).onProfileSelected(profiles[1]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.calls, ['sync']);
    expect(core.startedUris, isEmpty);
    expect(profileList(tester).selectedProfile?.uri, profiles[1].uri);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('vpn_profile_selected_uri'), profiles[1].uri);
  });

  testWidgets('connected tap waits for stop before starting selected route', (
    tester,
  ) async {
    final core = FakeVpnCore()
      ..phase = AndroidVpnPhase.running
      ..stopGate = Completer<void>();
    await pumpApp(tester, core);
    await tester.ensureVisible(find.byType(ProfileListView).first);
    await tester.pump();
    await tester.ensureVisible(find.text('Route2').last);
    await tester.tap(find.text('Route2').last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.calls, ['sync', 'stop']);
    expect(core.startedUris, isEmpty);
    expect(profileList(tester).selectedProfile?.uri, profiles.first.uri);

    core.stopGate!.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.calls, ['sync', 'stop', 'stop-complete', 'start']);
    expect(core.startedUris, [profiles[1].uri]);
    expect(core.isRunning, isTrue);
    expect(profileList(tester).selectedProfile?.uri, profiles[1].uri);
  });

  testWidgets('same route does not reconnect', (tester) async {
    final core = FakeVpnCore()..phase = AndroidVpnPhase.running;
    await pumpApp(tester, core);
    profileList(tester).onProfileSelected(profiles.first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.calls, isEmpty);
  });

  testWidgets('stale running UI cannot reconnect an externally stopped VPN', (
    tester,
  ) async {
    final core = FakeVpnCore()
      ..phase = AndroidVpnPhase.running
      ..phaseOnSync = AndroidVpnPhase.stopped;
    await pumpApp(tester, core);
    profileList(tester).onProfileSelected(profiles[1]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.calls, ['sync']);
    expect(core.startedUris, isEmpty);
    expect(profileList(tester).selectedProfile?.uri, profiles[1].uri);
  });

  for (final phase in [AndroidVpnPhase.starting, AndroidVpnPhase.stopping]) {
    testWidgets('ignores selection during externally initiated $phase', (
      tester,
    ) async {
      final core = FakeVpnCore()..phase = phase;
      await pumpApp(tester, core);
      profileList(tester).onProfileSelected(profiles[1]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(core.calls, ['sync']);
      expect(core.startedUris, isEmpty);
      expect(profileList(tester).selectedProfile?.uri, profiles.first.uri);
    });
  }

  testWidgets('rapid taps cannot replace the pending route or start twice', (
    tester,
  ) async {
    final core = FakeVpnCore()
      ..phase = AndroidVpnPhase.running
      ..syncGate = Completer<void>()
      ..stopGate = Completer<void>()
      ..startGate = Completer<void>();
    await pumpApp(tester, core);
    profileList(tester).onProfileSelected(profiles[1]);
    profileList(tester).onProfileSelected(profiles[2]);
    await tester.pump();
    core.syncGate!.complete();
    await tester.pump();
    profileList(tester).onProfileSelected(profiles[2]);
    core.stopGate!.complete();
    await tester.pump();
    profileList(tester).onProfileSelected(profiles[2]);
    core.startGate!.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.calls, ['sync', 'stop', 'stop-complete', 'start']);
    expect(core.startedUris, [profiles[1].uri]);
    expect(profileList(tester).selectedProfile?.uri, profiles[1].uri);
  });

  for (final phase in [AndroidVpnPhase.running, AndroidVpnPhase.stopping]) {
    testWidgets('does not start when old service remains $phase', (
      tester,
    ) async {
      final core = FakeVpnCore()
        ..phase = AndroidVpnPhase.running
        ..stopResult = phase;
      await pumpApp(tester, core);
      profileList(tester).onProfileSelected(profiles[1]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(core.startedUris, isEmpty);
      expect(profileList(tester).selectedProfile?.uri, profiles.first.uri);
    });
  }

  testWidgets('stop exception preserves selection and releases tap lock', (
    tester,
  ) async {
    final core = FakeVpnCore()
      ..phase = AndroidVpnPhase.running
      ..throwOnStop = true;
    await pumpApp(tester, core);
    profileList(tester).onProfileSelected(profiles[1]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.startedUris, isEmpty);
    expect(profileList(tester).selectedProfile?.uri, profiles.first.uri);
    core.throwOnStop = false;
    profileList(tester).onProfileSelected(profiles[1]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.startedUris, [profiles[1].uri]);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('failed new connection does not loop or display connected', (
    tester,
  ) async {
    final core = FakeVpnCore()
      ..phase = AndroidVpnPhase.running
      ..failStart = true;
    await pumpApp(tester, core);
    profileList(tester).onProfileSelected(profiles[1]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.startedUris, [
      profiles[1].uri,
    ], reason: '${core.calls} ${core.phase}');
    expect(core.isRunning, isFalse);
    expect(profileList(tester).selectedProfile?.uri, profiles[1].uri);
    expect(find.byTooltip('Подключить VPN'), findsWidgets);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('main button can cancel the new connection during switching', (
    tester,
  ) async {
    final core = FakeVpnCore()
      ..phase = AndroidVpnPhase.running
      ..startGate = Completer<void>();
    await pumpApp(tester, core);
    profileList(tester).onProfileSelected(profiles[1]);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('main-connect-button')));
    await tester.pump(const Duration(milliseconds: 100));
    core.startGate!.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.startedUris, [profiles[1].uri]);
    expect(core.isRunning, isFalse);
    expect(find.byTooltip('Подключить VPN'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposal during stop cannot trigger a later reconnect', (
    tester,
  ) async {
    final core = FakeVpnCore()
      ..phase = AndroidVpnPhase.running
      ..stopGate = Completer<void>();
    await pumpApp(tester, core);
    profileList(tester).onProfileSelected(profiles[1]);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    core.stopGate!.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(core.startedUris, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
