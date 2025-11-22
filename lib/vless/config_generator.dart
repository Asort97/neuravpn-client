import 'dart:convert';
import 'vless_parser.dart';

import '../models/split_tunnel_config.dart';

/// Генерация конфигурационного JSON для sing-box с TUN (wintun)
/// Полноценный VPN туннель для всего устройства без SOCKS прокси
String generateSingBoxConfig(
  VlessLink link,
  SplitTunnelConfig splitConfig, {
  String inboundTag = 'tun-in',
  String interfaceName = 'wintun0',
  List<String>? addresses,
}) {
  final p = link.params;
  final transportType = p['type']; // например ws, tcp, grpc, h2
  final security = p['security'];
  final isReality = security == 'reality';
  final useTls = (security == 'tls' || isReality);
  final serverName = p['sni'] ?? p['host'] ?? link.host;
  final alpn = p['alpn'] != null ? p['alpn']!.split(',') : [];
  final flow = p['flow'];
  final fingerprint = p['fp'] ?? 'chrome';
  final path = p['path'];
  final realityPublicKey = p['pbk'];
  final realityShortId = p['sid'];
  final packetEncoding = p['packetEncoding'] ?? p['packet'];
  // sing-box не принимает поле spider_x (spx) в текущей версии — игнорируем

  final outbound = <String, dynamic>{
    'type': 'vless',
    'tag': link.tag ?? 'vless-out',
    'server': link.host,
    'server_port': link.port,
    'uuid': link.uuid,
    'domain_strategy': 'ipv4_only',
  };

  if (flow != null && flow.isNotEmpty) {
    outbound['flow'] = flow;
    if ((packetEncoding == null || packetEncoding.isEmpty) && flow.contains('vision')) {
      outbound['packet_encoding'] = 'xudp';
    }
  }

  if (packetEncoding != null && packetEncoding.isNotEmpty) {
    outbound['packet_encoding'] = packetEncoding;
  }

  if (useTls) {
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': serverName,
      if (alpn.isNotEmpty) 'alpn': alpn,
      'utls': {
        'enabled': true,
        'fingerprint': fingerprint,
      }
    };
    if (isReality) {
      final shortIdList = (realityShortId ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      tls['reality'] = {
        'enabled': true,
        if (realityPublicKey != null && realityPublicKey.isNotEmpty)
          'public_key': realityPublicKey,
        if (shortIdList.isNotEmpty)
          'short_id': shortIdList.length == 1 ? shortIdList.first : shortIdList,
      };
    }
    outbound['tls'] = tls;
  }

  // transportType=tcp в sing-box не задаётся как отдельный transport.
  if (transportType != null && transportType.isNotEmpty && transportType != 'tcp') {
    final transport = <String, dynamic>{'type': transportType};
    if (transportType == 'ws') {
      if (path != null && path.isNotEmpty) transport['path'] = path;
      final hostHeader = p['host'] ?? link.host;
      transport['headers'] = {'Host': hostHeader};
    }
    outbound['transport'] = transport;
  }

  final config = {
    'log': {
      'level': 'info',
      'timestamp': true,
    },
    'dns': {
      'servers': [
        {
          'tag': 'dns-remote',
          'address': '1.1.1.1',
        },
        {
          'tag': 'dns-local',
          'address': 'local',
          'detour': 'direct',
        },
      ],
      'final': 'dns-remote',
    },
    'inbounds': [
      {
        'type': 'tun',
        'tag': inboundTag,
        'interface_name': interfaceName,
        'stack': 'system',
        'mtu': 1400,
        'address': addresses ?? const ['172.19.0.1/30'],
        'auto_route': true,
        'strict_route': false,
        'sniff': true,
        'sniff_override_destination': false,
      }
    ],
    'outbounds': [
      outbound,
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {
      'auto_detect_interface': true,
      'final': _getDefaultOutbound(splitConfig, link.tag ?? 'vless-out'),
      'rules': [
        ..._buildRouteRules(splitConfig, link.tag ?? 'vless-out'),
      ],
    }
  };
  return const JsonEncoder.withIndent('  ').convert(config);
}

String _getDefaultOutbound(SplitTunnelConfig config, String vpnTag) {
  if (config.mode == 'whitelist') return 'direct'; // По умолчанию direct, VPN только для списка
  return vpnTag; // all или blacklist — по умолчанию через VPN
}

List<Map<String, dynamic>> _buildRouteRules(SplitTunnelConfig config, String vpnTag) {
  final rules = <Map<String, dynamic>>[];
  
  if (config.domains.isEmpty) return rules;

  final targets = _RouteTargets.fromEntries(config.domains);

  if (config.mode == 'whitelist') {
    // Только указанные домены/IP через VPN, остальное direct
    if (targets.hasDomainRules || targets.ipCidrs.isNotEmpty) {
      rules.add({
        ...targets.toSingBoxFields(),
        if (targets.ipCidrs.isNotEmpty) 'ip_cidr': targets.ipCidrs,
        'outbound': vpnTag,
      });
    }
  } else if (config.mode == 'blacklist') {
    if (targets.hasDomainRules || targets.ipCidrs.isNotEmpty) {
      rules.add({
        ...targets.toSingBoxFields(),
        if (targets.ipCidrs.isNotEmpty) 'ip_cidr': targets.ipCidrs,
        'outbound': 'direct',
      });
    }
  }
  
  return rules;
}

class _RouteTargets {
  _RouteTargets({
    required this.domainFull,
    required this.domainSuffix,
    required this.domainKeyword,
    required this.domainRegex,
    required this.geosite,
    required this.ipCidrs,
  });

  final List<String> domainFull;
  final List<String> domainSuffix;
  final List<String> domainKeyword;
  final List<String> domainRegex;
  final List<String> geosite;
  final List<String> ipCidrs;

  bool get hasDomainRules => domainFull.isNotEmpty ||
      domainSuffix.isNotEmpty ||
      domainKeyword.isNotEmpty ||
      domainRegex.isNotEmpty ||
      geosite.isNotEmpty;

  Map<String, dynamic> toSingBoxFields() => {
        if (domainFull.isNotEmpty) 'domain': domainFull,
        if (domainSuffix.isNotEmpty) 'domain_suffix': domainSuffix,
        if (domainKeyword.isNotEmpty) 'domain_keyword': domainKeyword,
        if (domainRegex.isNotEmpty) 'domain_regex': domainRegex,
        if (geosite.isNotEmpty) 'geosite': geosite,
      };

  static _RouteTargets fromEntries(List<String> entries) {
    final domainFull = <String>[];
    final domainSuffix = <String>[];
    final domainKeyword = <String>[];
    final domainRegex = <String>[];
    final geosite = <String>[];
    final ipCidrs = <String>[];

    for (final raw in entries) {
      final value = raw.trim();
      if (value.isEmpty) continue;

      if (_looksLikeIpv4(value) || _looksLikeIpv6(value)) {
        ipCidrs.add(_ensureCidr(value));
        continue;
      }

      if (_looksLikeCidr(value)) {
        ipCidrs.add(value);
        continue;
      }

      final lower = value.toLowerCase();
      if (lower.startsWith('geosite:')) {
        geosite.add(value.substring('geosite:'.length));
        continue;
      }

      final suffix = _stripPrefix(lower, value, ['domain-suffix:', 'domain_suffix:', 'suffix:']);
      if (suffix != null) {
        domainSuffix.add(suffix);
        continue;
      }

      final keyword = _stripPrefix(lower, value, ['domain-keyword:', 'domain_keyword:', 'keyword:']);
      if (keyword != null) {
        domainKeyword.add(keyword);
        continue;
      }

      final full = _stripPrefix(lower, value, ['domain-full:', 'domain_full:', 'full:', 'domain:']);
      if (full != null) {
        domainFull.add(full);
        continue;
      }

      final regex = _stripPrefix(lower, value, ['domain-regex:', 'domain_regex:', 'regexp:', 'regex:']);
      if (regex != null) {
        domainRegex.add(regex);
        continue;
      }

      // Default: treat as suffix-based domain
      domainSuffix.add(value);
    }

    return _RouteTargets(
      domainFull: domainFull,
      domainSuffix: domainSuffix,
      domainKeyword: domainKeyword,
      domainRegex: domainRegex,
      geosite: geosite,
      ipCidrs: ipCidrs,
    );
  }

  static bool _looksLikeIpv4(String value) {
    final ipv4 = RegExp(r'^(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}$');
    return ipv4.hasMatch(value);
  }

  static bool _looksLikeIpv6(String value) {
    // Simplified IPv6 check — validates presence of ':' without invalid characters
    if (!value.contains(':')) return false;
    final ipv6 = RegExp(r'^[0-9a-fA-F:]+$');
    return ipv6.hasMatch(value);
  }

  static String _ensureCidr(String ip) {
    if (ip.contains('/')) return ip;
    if (_looksLikeIpv4(ip)) return '$ip/32';
    return '$ip/128';
  }

  static bool _looksLikeCidr(String value) {
    final cidr = RegExp(r'^([0-9a-fA-F:.]+)/\d{1,3}$');
    return cidr.hasMatch(value);
  }

  static String? _stripPrefix(String lower, String original, List<String> prefixes) {
    for (final prefix in prefixes) {
      if (lower.startsWith(prefix)) {
        return original.substring(prefix.length);
      }
    }
    return null;
  }
}
