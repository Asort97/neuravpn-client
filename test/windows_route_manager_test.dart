import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/windows_route_manager.dart';

class _UnsupportedNativeRouteApi implements WindowsRouteNativeApi {
  const _UnsupportedNativeRouteApi();

  @override
  Future<WindowsRouteUplink?> discoverPrimaryUplink() async => null;

  @override
  Future<WindowsRouteNativeApplyResult> applyRoutes({
    required String preferredTunInterface,
    required String tunAddress,
    required int tunPrefixLength,
    required WindowsRouteUplink uplink,
    required List<String> protectedPrefixes,
  }) async => const WindowsRouteNativeApplyResult.unsupported();
}

class _SuccessfulNativeRouteApi implements WindowsRouteNativeApi {
  const _SuccessfulNativeRouteApi();

  @override
  Future<WindowsRouteUplink?> discoverPrimaryUplink() async => null;

  @override
  Future<WindowsRouteNativeApplyResult> applyRoutes({
    required String preferredTunInterface,
    required String tunAddress,
    required int tunPrefixLength,
    required WindowsRouteUplink uplink,
    required List<String> protectedPrefixes,
  }) async {
    expect(tunPrefixLength, 30);
    return WindowsRouteNativeApplyResult(
      supported: true,
      session: WindowsRouteSession(
        tunInterfaceName: preferredTunInterface,
        tunInterfaceIndex: 88,
        tunAddress: tunAddress,
        uplinkInterfaceName: uplink.interfaceName,
        uplinkInterfaceIndex: uplink.interfaceIndex,
        uplinkGateway: uplink.gateway,
        uplinkAddress: uplink.localAddress,
        protectedPrefixes: protectedPrefixes,
      ),
    );
  }
}

void main() {
  test(
    'applyRoutes uses single fast PowerShell batch when uplink is known',
    () async {
      final scripts = <String>[];
      final manager = WindowsRouteManager(
        nativeApi: const _UnsupportedNativeRouteApi(),
        isWindowsOverride: true,
        processRunner: (executable, arguments) async {
          expect(executable, 'powershell');
          final script = arguments.last;
          scripts.add(script);
          return ProcessResult(
            1,
            0,
            '{"Success":true,"TunName":"tun-in-test","TunInterfaceIndex":77,"TunAddress":"172.25.1.1"}',
            '',
          );
        },
      );

      final result = await manager.applyRoutes(
        preferredTunInterface: 'tun-in-test',
        remoteHost: '203.0.113.10',
        dnsServers: const <String>['8.8.8.8'],
        tunAddressHint: '172.25.1.1/30',
        uplink: const WindowsRouteUplink(
          interfaceName: 'Ethernet',
          interfaceIndex: 12,
          gateway: '192.168.0.1',
          localAddress: '192.168.0.100',
        ),
      );

      expect(result.success, isTrue);
      expect(result.session?.tunInterfaceIndex, 77);
      expect(result.session?.protectedPrefixes, <String>[
        '203.0.113.10',
        '8.8.8.8',
      ]);
      expect(scripts, hasLength(1));
      expect(scripts.single, contains('Get-NetAdapter -IncludeHidden'));
      expect(scripts.single, contains('New-NetIPAddress -InterfaceIndex'));
      expect(
        scripts.single,
        contains('-IPAddress \$tunAddress -PrefixLength \$tunPrefixLength'),
      );
      expect(
        scripts.single,
        isNot(contains('Set-NetIPInterface -InterfaceIndex')),
      );
      expect(scripts.single, contains('-RouteMetric 4'));
      expect(scripts.single, contains('-RouteMetric 5'));
      expect(scripts.single, isNot(contains("DestinationPrefix '0.0.0.0/1'")));
      expect(
        scripts.single,
        isNot(contains("DestinationPrefix '128.0.0.0/1'")),
      );
      expect(
        scripts.single,
        contains(
          "New-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex "
          r"$selected.InterfaceIndex -NextHop '0.0.0.0'",
        ),
      );
    },
  );

  test('applyRoutes prefers native batch and skips PowerShell', () async {
    final manager = WindowsRouteManager(
      nativeApi: const _SuccessfulNativeRouteApi(),
      useNativeRouteApi: true,
      isWindowsOverride: true,
      processRunner: (executable, arguments) async {
        fail('PowerShell should not be launched when native route setup works');
      },
    );

    final result = await manager.applyRoutes(
      preferredTunInterface: 'tun-in-native',
      remoteHost: '203.0.113.10',
      dnsServers: const <String>['8.8.8.8'],
      tunAddressHint: '172.25.1.1/30',
      uplink: const WindowsRouteUplink(
        interfaceName: 'Ethernet',
        interfaceIndex: 12,
        gateway: '192.168.0.1',
        localAddress: '192.168.0.100',
      ),
    );

    expect(result.success, isTrue);
    expect(result.session?.tunInterfaceName, 'tun-in-native');
    expect(
      result.logs,
      contains('Route batch applied natively through tun-in-native'),
    );
  });
}
