import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'vless_parser.dart';

import '../models/split_tunnel_config.dart';
import '../services/dpi_evasion_config.dart';

/// Генерация конфигурационного JSON для sing-box с TUN (wintun)
/// Полноценный VPN туннель для всего устройства без SOCKS прокси
String generateSingBoxConfig(
  VlessLink link,
  SplitTunnelConfig splitConfig, {
  String inboundTag = 'tun-in',
  String interfaceName = 'wintun0',
  List<String>? addresses,
  String tunStack = 'system',
  bool enableApplicationRules = false,
  bool hasAndroidPackageRules = false,
  bool autoDetectInterface = true,
  bool smartRouting = false,
  List<String> smartDomains = const <String>[],
  List<Map<String, dynamic>> extraRouteRules = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> extraOutbounds = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> extraInbounds = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>>? dnsServers,
  String? dnsFinalTag,
  DpiEvasionConfig dpiEvasionConfig = DpiEvasionConfig.balanced,
  int? clashApiPort,
  String logLevel = 'info',
}) {
  final p = link.params;
  final transportType = p['type']; // например ws, tcp, grpc, h2
  final security = p['security'];
  final isReality = security == 'reality';
  final useTls = (security == 'tls' || isReality);
  final serverName = p['sni'] ?? p['host'] ?? link.host;
  final alpn = p['alpn'] != null
      ? p['alpn']!.split(',')
      : (useTls ? <String>['h2', 'http/1.1'] : <String>[]);
  final flow = p['flow'] ?? '';
  final isVision = flow.contains('vision');
  final fingerprint = p['fp'] ?? 'chrome';
  final path = p['path'];
  final realityPublicKey = p['pbk'];
  final realityShortId = p['sid'];
  final packetEncoding = p['packetEncoding'] ?? p['packet'];

  final vpnTag = link.tag ?? 'vless-out';

  final outbound = <String, dynamic>{
    'type': 'vless',
    'tag': vpnTag,
    'server': link.host,
    'server_port': link.port,
    'uuid': link.uuid,
    // sing-box 1.12+: use domain_resolver instead of deprecated domain_strategy
    'domain_resolver': 'dns-remote',
  };

  if (flow.isNotEmpty) {
    outbound['flow'] = flow;
    if ((packetEncoding == null || packetEncoding.isEmpty) && isVision) {
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
      'utls': {'enabled': true, 'fingerprint': fingerprint},
    };
    // Отключаем TLS handshake fragmentation: в текущей версии ломает соединения.
    tls['fragment'] = false;
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

  // transport: для vision/Reality убираем; иначе обычное построение
  if (!isVision && !isReality) {
    final transport = _buildTransport(transportType, link, p, path, serverName);
    if (transport != null) {
      outbound['transport'] = transport;
    }
  }
  if (dpiEvasionConfig.enableFragmentation &&
      dpiEvasionConfig.enableTlsFragment &&
      useTls) {
    _applyFragmentation(outbound, transportType);
  }

  // Multiplex: включаем smux без padding, чтобы не рвать сессии.
  if (dpiEvasionConfig.enableMultiplexPadding) {
    outbound['multiplex'] = {
      'enabled': true,
      'protocol': 'smux',
      'padding': false,
    };
  }


  final appRules = enableApplicationRules
      ? _buildApplicationRules(splitConfig, vpnTag)
      : const <Map<String, dynamic>>[];

  final smartRules = smartRouting
      ? _buildSmartRules(smartDomains, vpnTag)
      : const <Map<String, dynamic>>[];

  final config = {
    'log': {'level': logLevel, 'timestamp': true, 'output': 'stderr'},
    'dns': {
      'servers': dnsServers ?? [
        {
          // Avoid DNS loopback with TUN by sending DNS traffic via direct.
          'type': 'udp',
          'tag': 'dns-remote',
          'server': '8.8.8.8',
          'server_port': 53,
        },
        {
          'type': 'udp',
          'tag': 'dns-backup',
          'server': '1.1.1.1',
          'server_port': 53,
        },
      ],
      'final': dnsFinalTag ?? 'dns-remote',
      'strategy': 'prefer_ipv4',
      'independent_cache': true,
      'disable_cache': false,
      'disable_expire': false,
    },
    'inbounds': [
      {
        'type': 'tun',
        'tag': inboundTag,
        'interface_name': interfaceName,
        'stack': tunStack,
        'mtu': 1280,  // Уменьшено с 1500 - часто вызывает проблемы на Windows
        'address': addresses ?? const ['172.19.0.1/30'],
        'auto_route': true,
        // Windows: recommended to prevent multihomed DNS leaks and enforce routing.
        'strict_route': true,
        // Ensure both IPv4 and IPv6 default routes are captured.
        'route_address': const ['0.0.0.0/1', '128.0.0.0/1'],  // Убрали IPv6 для стабильности
        'sniff': true,
        'sniff_override_destination': false,
      },
      ...extraInbounds,
    ],
    'outbounds': [
      _optimizeOutbound(outbound, vpnTag),
      {'type': 'direct', 'tag': 'direct'},
      ...extraOutbounds,
    ],
    'route': {
      'auto_detect_interface': autoDetectInterface,
      'default_domain_resolver': dnsFinalTag ?? 'dns-remote',
      'final': _getDefaultOutbound(
        splitConfig,
        vpnTag,
        hasAndroidPackageRules: hasAndroidPackageRules,
      ),
      'rules': [
        // Hijack DNS queries using rule action instead of legacy dns outbound
        {'protocol': 'dns', 'action': 'hijack-dns'},

        ...smartRules,
        ...extraRouteRules,
        ..._buildRouteRules(splitConfig, vpnTag),
        ...appRules,
      ],
    },
  };
  if (clashApiPort != null) {
    config['experimental'] = {
      'clash_api': {
        'external_controller': '127.0.0.1:$clashApiPort',
      },
    };
  }
  return const JsonEncoder.withIndent('  ').convert(config);
}

void _applyFragmentation(Map<String, dynamic> outbound, String? transportType) {
  const fragment = {
    'packets': 'tlshello',
    'length': '1-5',
    'interval': '10-20',
  };

  final existingTransport = outbound['transport'];
  if (existingTransport is Map<String, dynamic>) {
    final type = existingTransport['type'];
    if (type is String && type.isNotEmpty) {
      outbound['transport'] = <String, dynamic>{
        ...existingTransport,
        'fragment': fragment,
      };
    }
    return;
  }

  final normalizedType = transportType?.trim().toLowerCase();
  if (normalizedType != null &&
      normalizedType.isNotEmpty &&
      normalizedType != 'tcp') {
    outbound['transport'] = <String, dynamic>{
      'type': normalizedType,
      'fragment': fragment,
    };
  }
}

Map<String, dynamic> _optimizeOutbound(
  Map<String, dynamic> outbound,
  String vpnTag,
) {
  // ⚡ Минимальная оптимизация: TCP Fast Open
  final optimized = Map<String, dynamic>.from(outbound);
  optimized['tcp_fast_open'] = true;
  return optimized;
}

String _getDefaultOutbound(
  SplitTunnelConfig config,
  String vpnTag, {
  required bool hasAndroidPackageRules,
}) {
  if (config.mode == 'whitelist') {
    final hasDomainRules = config.domains.isNotEmpty;
    if (!hasDomainRules && hasAndroidPackageRules) {
      return vpnTag;
    }
    return 'direct';
  }
  return vpnTag; // all или blacklist — по умолчанию через VPN
}

List<Map<String, dynamic>> _buildRouteRules(
  SplitTunnelConfig config,
  String vpnTag,
) {
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

List<Map<String, dynamic>> _buildSmartRules(
  List<String> smartDomains,
  String vpnTag,
) {
  if (smartDomains.isEmpty) return const <Map<String, dynamic>>[];
  final domainSuffix = <String>[];
  final domains = <String>[];
  for (final entry in smartDomains) {
    final value = entry.trim();
    if (value.isEmpty) continue;
    if (value.startsWith('.')) {
      domainSuffix.add(value.replaceFirst('.', ''));
    } else if (!value.contains('.')) {
      domainSuffix.add(value);
    } else {
      domains.add(value);
    }
  }
  final rule = <String, dynamic>{
    if (domainSuffix.isNotEmpty) 'domain_suffix': domainSuffix,
    if (domains.isNotEmpty) 'domain': domains,
    'outbound': 'direct',
  };
  return [rule];
}

List<Map<String, dynamic>> _buildApplicationRules(
  SplitTunnelConfig config,
  String vpnTag,
) {
  if (config.mode == 'all' || config.applications.isEmpty) {
    return const <Map<String, dynamic>>[];
  }

  final cleaned = <_ApplicationRule>[];
  for (final entry in config.applications) {
    final value = entry.trim();
    if (value.isEmpty) continue;
    cleaned.addAll(_parseApplicationRules(value));
  }
  if (cleaned.isEmpty) return const <Map<String, dynamic>>[];

  // Deduplicate identical rules.
  final seen = <String>{};
  final unique = <_ApplicationRule>[];
  for (final rule in cleaned) {
    final key = '${rule.key}:${rule.value}';
    if (seen.add(key)) {
      unique.add(rule);
    }
  }

  final outbound = config.mode == 'whitelist' ? vpnTag : 'direct';
  return unique
      .map((rule) => {rule.key: rule.value, 'outbound': outbound})
      .toList();
}

class _ApplicationRule {
  const _ApplicationRule(this.key, this.value);

  final String key;
  final String value;
}

List<_ApplicationRule> _parseApplicationRules(String entry) {
  if (entry.isEmpty) return const <_ApplicationRule>[];

  if (entry.startsWith('package:')) {
    final pkg = entry.substring('package:'.length).trim();
    if (pkg.isEmpty) return const <_ApplicationRule>[];
    return <_ApplicationRule>[_ApplicationRule('package_name', pkg)];
  }

  final normalized = entry.trim();
  if (_looksLikePath(normalized)) {
    final exeName = path.basename(normalized);
    final rules = <_ApplicationRule>[
      _ApplicationRule('process_path', normalized),
    ];
    if (exeName.isNotEmpty && exeName.contains('.')) {
      rules.add(_ApplicationRule('process_name', exeName));
    }

    // Universal parent->child process support:
    // include descendant executables from the app directory so child processes
    // spawned by launchers/updaters are routed too.
    for (final childExe in _collectDescendantExecutables(normalized)) {
      final childName = path.basename(childExe);
      if (childName.isEmpty) continue;
      rules.add(_ApplicationRule('process_path', childExe));
      rules.add(_ApplicationRule('process_name', childName));
    }
    return rules;
  }

  return <_ApplicationRule>[_ApplicationRule('process_name', normalized)];
}

bool _looksLikePath(String value) {
  return value.contains(':') || value.contains('/') || value.contains('\\');
}

List<String> _collectDescendantExecutables(String selectedExePath) {
  final selected = File(selectedExePath);
  if (!selected.existsSync()) return const <String>[];

  final root = selected.parent;
  if (!root.existsSync()) return const <String>[];

  const maxDepth = 3;
  const maxCount = 32;
  final selectedLower = selected.path.toLowerCase();
  final discovered = <String>[];

  List<FileSystemEntity> entities;
  try {
    entities = root.listSync(recursive: true, followLinks: false);
  } catch (_) {
    return const <String>[];
  }

  for (final entity in entities) {
    if (discovered.length >= maxCount) break;
    if (entity is! File) continue;

    final fullPath = entity.path;
    if (!fullPath.toLowerCase().endsWith('.exe')) continue;
    if (fullPath.toLowerCase() == selectedLower) continue;

    final relPath = path.relative(fullPath, from: root.path);
    final depth = path.split(relPath).length - 1;
    if (depth > maxDepth) continue;

    discovered.add(fullPath);
  }

  return discovered;
}

Map<String, dynamic>? _buildTransport(
  String? transportType,
  VlessLink link,
  Map<String, String> params,
  String? path,
  String serverName,
) {
  final normalizedType = transportType?.toLowerCase();
  final headerHost = _firstParam(params, ['host', 'Host']) ?? link.host;

  if (normalizedType == null ||
      normalizedType.isEmpty ||
      normalizedType == 'tcp') {
    final headerType = _firstParam(params, [
      'headerType',
      'header_type',
    ])?.toLowerCase();
    if (headerType == 'http') {
      return _buildHttpTransport(params, path, headerHost, serverName);
    }
    return null;
  }

  switch (normalizedType) {
    case 'ws':
      return {
        'type': 'ws',
        if (path != null && path.isNotEmpty) 'path': path,
        'headers': {'Host': headerHost},
      };
    case 'grpc':
      final serviceName =
          _firstParam(params, ['serviceName', 'service_name', 'servicename']) ??
          path?.replaceFirst(RegExp(r'^/'), '');
      final authority = _firstParam(params, ['authority']) ?? headerHost;
      final multiMode = _parseBool(
        _firstParam(params, ['multiMode', 'multimode']),
      );
      final idleTimeout = _firstParam(params, ['idle_timeout', 'idleTimeout']);
      return {
        'type': 'grpc',
        if (serviceName != null && serviceName.isNotEmpty)
          'service_name': serviceName,
        if (authority.isNotEmpty) 'authority': authority,
        if (multiMode != null) 'multi_mode': multiMode,
        if (idleTimeout != null && idleTimeout.isNotEmpty)
          'idle_timeout': idleTimeout,
        if (params['mode'] != null && params['mode']!.isNotEmpty)
          'mode': params['mode'],
      };
    case 'xhttp':
    case 'http':
    case 'h2':
      return _buildHttpTransport(params, path, headerHost, serverName);
    case 'httpupgrade':
      return {
        'type': 'httpupgrade',
        if (path != null && path.isNotEmpty) 'path': path,
        'headers': {'Host': headerHost},
      };
    case 'quic':
      final security =
          _firstParam(params, ['quicSecurity', 'quic_security']) ?? 'none';
      final key = _firstParam(params, ['key', 'quicKey', 'quic_key']);
      return {
        'type': 'quic',
        'security': security,
        if (key != null && key.isNotEmpty) 'key': key,
        if (path != null && path.isNotEmpty) 'path': path,
        'headers': {'Host': headerHost},
      };
    default:
      return {'type': normalizedType};
  }
}

Map<String, dynamic> _buildHttpTransport(
  Map<String, String> params,
  String? path,
  String headerHost,
  String serverName,
) {
  final hosts = _splitCsv(_firstParam(params, ['host', 'hosts']));
  if (hosts.isEmpty && headerHost.isNotEmpty) {
    hosts.add(headerHost);
  }
  final method = _firstParam(params, ['method']) ?? 'GET';
  final headers = <String, String>{};
  final headerOverride = _firstParam(params, ['header', 'headers']);
  if (headerOverride != null && headerOverride.contains(':')) {
    for (final entry in headerOverride.split('|')) {
      final parts = entry.split(':');
      if (parts.length >= 2) {
        headers[parts[0].trim()] = parts.sublist(1).join(':').trim();
      }
    }
  }
  if (!headers.containsKey('Host') && hosts.isNotEmpty) {
    headers['Host'] = hosts.first;
  }
  if (!headers.containsKey('Authority')) {
    final authority = _firstParam(params, ['authority']);
    if (authority != null && authority.isNotEmpty) {
      headers['Authority'] = authority;
    }
  }
  if (!headers.containsKey('User-Agent')) {
    final ua = _firstParam(params, ['ua', 'userAgent', 'user_agent']);
    if (ua != null && ua.isNotEmpty) headers['User-Agent'] = ua;
  }

  return {
    'type': 'http',
    'method': method,
    if (path != null && path.isNotEmpty) 'path': path,
    if (hosts.isNotEmpty) 'host': hosts,
    if (headers.isNotEmpty) 'headers': headers,
  };
}

String? _firstParam(Map<String, String> params, List<String> keys) {
  for (final key in keys) {
    final value = params[key];
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

List<String> _splitCsv(String? raw) {
  if (raw == null || raw.isEmpty) return <String>[];
  return raw
      .split(',')
      .map((e) => e.trim())
      .where((element) => element.isNotEmpty)
      .toList();
}

bool? _parseBool(String? raw) {
  if (raw == null) return null;
  final lower = raw.toLowerCase();
  if (lower == 'true' || lower == '1') return true;
  if (lower == 'false' || lower == '0') return false;
  return null;
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

  bool get hasDomainRules =>
      domainFull.isNotEmpty ||
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

      final suffix = _stripPrefix(lower, value, [
        'domain-suffix:',
        'domain_suffix:',
        'suffix:',
      ]);
      if (suffix != null) {
        domainSuffix.add(suffix);
        continue;
      }

      final keyword = _stripPrefix(lower, value, [
        'domain-keyword:',
        'domain_keyword:',
        'keyword:',
      ]);
      if (keyword != null) {
        domainKeyword.add(keyword);
        continue;
      }

      final full = _stripPrefix(lower, value, [
        'domain-full:',
        'domain_full:',
        'full:',
        'domain:',
      ]);
      if (full != null) {
        domainFull.add(full);
        continue;
      }

      final regex = _stripPrefix(lower, value, [
        'domain-regex:',
        'domain_regex:',
        'regexp:',
        'regex:',
      ]);
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
    final ipv4 = RegExp(
      r'^(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}$',
    );
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

  static String? _stripPrefix(
    String lower,
    String original,
    List<String> prefixes,
  ) {
    for (final prefix in prefixes) {
      if (lower.startsWith(prefix)) {
        return original.substring(prefix.length);
      }
    }
    return null;
  }
}
