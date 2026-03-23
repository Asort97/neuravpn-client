import 'dart:convert';

import '../models/split_tunnel_config.dart';
import '../vless/config_generator.dart';
import '../vless/vless_parser.dart';
import 'dpi_evasion_config.dart';
import 'windows_vpn_core.dart';

class WindowsXrayCoreAdapter implements WindowsVpnCoreAdapter {
  static const int defaultApiPort = 10085;

  @override
  String get processName => 'xray.exe';

  @override
  int get apiPort => defaultApiPort;

  @override
  String generateConfig({
    required VlessLink parsed,
    required SplitTunnelConfig splitConfig,
    required String inboundTag,
    required String interfaceName,
    required List<String> interfaceAddresses,
    String? outboundInterfaceName,
    String? outboundBindAddress,
    required List<Map<String, dynamic>> extraRouteRules,
    required DpiEvasionConfig dpiEvasionConfig,
    required bool developerMode,
  }) {
    return generateXrayConfig(
      parsed,
      splitConfig,
      inboundTag: inboundTag,
      interfaceName: interfaceName,
      addresses: interfaceAddresses,
      outboundInterfaceName: outboundInterfaceName,
      outboundBindAddress: outboundBindAddress,
      tunStack: 'system',
      smartRouting: splitConfig.smartRouting,
      smartDomains: splitConfig.smartDomains,
      extraRouteRules: extraRouteRules,
      apiPort: apiPort,
      logLevel: developerMode ? 'debug' : 'info',
    );
  }

  @override
  String? computeRuleHash(String jsonConfig) {
    try {
      final decoded = jsonDecode(jsonConfig);
      if (decoded is! Map<String, dynamic>) return null;
      final routing = decoded['routing'];
      if (routing == null) return null;
      return jsonEncode(routing);
    } catch (_) {
      return null;
    }
  }
}
