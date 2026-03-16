import '../models/split_tunnel_config.dart';
import '../vless/vless_parser.dart';
import 'dpi_evasion_config.dart';

typedef WindowsCoreProcessRunner =
    Future<dynamic> Function(String executable, List<String> arguments);

abstract class WindowsVpnCoreAdapter {
  String get processName;
  int get apiPort;

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
  });

  String? computeRuleHash(String jsonConfig);
}
