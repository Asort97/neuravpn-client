import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/models/split_tunnel_config.dart';
import 'package:happycat_vpnclient/vless/config_generator.dart';
import 'package:happycat_vpnclient/vless/vless_parser.dart';

void main() {
  test('bundled Windows cores accept hybrid runtime configs', () async {
    if (!Platform.isWindows) return;

    final xray = File('assets/bin/xray.exe').absolute;
    final singBox = File('assets/bin/sing-box.exe').absolute;
    expect(xray.existsSync(), isTrue);
    expect(singBox.existsSync(), isTrue);

    final link = parseVlessUri(
      'vless://11111111-1111-1111-1111-111111111111@example.com:443'
      '?security=reality&type=xhttp&sni=example.com'
      '&pbk=pkKO6JYPzg5UIiUdyksPj1eK5iPlA_ccqOQmDhGvhmc'
      '&sid=abcd&path=%2Fedge#proxy',
    )!;
    final splitConfig = SplitTunnelConfig(mode: 'all');
    final tempDir = await Directory.systemTemp.createTemp(
      'neuravpn_hybrid_config_test_',
    );
    try {
      final xrayConfig = File('${tempDir.path}/xray.json');
      await xrayConfig.writeAsString(
        generateWindowsXrayProxyConfig(link, splitConfig),
      );
      final xrayResult = await Process.run(xray.path, <String>[
        'run',
        '-test',
        '-c',
        xrayConfig.path,
      ]);
      expect(
        xrayResult.exitCode,
        0,
        reason: '${xrayResult.stderr}\n${xrayResult.stdout}',
      );

      final singBoxConfig = File('${tempDir.path}/sing-box.json');
      await singBoxConfig.writeAsString(
        generateWindowsHybridTunConfig(
          splitConfig,
          inboundTag: 'tun-in-test',
          interfaceName: 'tun-in-test',
          addresses: const <String>['172.25.10.1/30'],
        ),
      );
      final singBoxResult = await Process.run(singBox.path, <String>[
        'check',
        '-c',
        singBoxConfig.path,
      ]);
      expect(
        singBoxResult.exitCode,
        0,
        reason: '${singBoxResult.stderr}\n${singBoxResult.stdout}',
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}
