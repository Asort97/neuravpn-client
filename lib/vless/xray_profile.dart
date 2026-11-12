import 'dart:convert';

import 'proxy_link.dart';

/// A complete subscription profile, not a URI for its first outbound.
/// Stored in the existing per-subscription profile list as canonical JSON.
class XrayProfile extends ProxyLink {
  XrayProfile._(this._json, this._name, this.endpointHosts, this.isAutomatic);

  final String _json;
  final String _name;
  final Set<String> endpointHosts;
  final bool isAutomatic;

  Map<String, dynamic> get config => jsonDecode(_json) as Map<String, dynamic>;
  String get serialized => _json;
  String get primaryInboundTag {
    final inbounds = (config['inbounds'] as List).cast<Map<String, dynamic>>();
    return inbounds.firstWhere(
          (inbound) => inbound['protocol'] == 'socks',
          orElse: () => inbounds.first,
        )['tag']
        as String;
  }

  @override
  String get tag => _name;
  @override
  String get host => endpointHosts.first;
  @override
  int get port => 0; // Never measure one candidate as the whole profile.
  @override
  Map<String, String> get params => const {};
  @override
  String get protocolLabel => isAutomatic ? 'Xray Auto' : 'Xray';

  static XrayProfile? tryParse(String raw) {
    if (!raw.trimLeft().startsWith('{')) return null;
    try {
      return fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Never _invalid() => throw const FormatException(
    'Подписка содержит небезопасный или неподдерживаемый Xray-профиль.',
  );

  static Map<String, dynamic> _map(dynamic value) {
    if (value is! Map<String, dynamic>) _invalid();
    return value;
  }

  static List<dynamic> _list(dynamic value) {
    if (value is! List) _invalid();
    return value;
  }

  static void _keys(Map<String, dynamic> value, Set<String> allowed) {
    if (value.keys.any((key) => !allowed.contains(key))) _invalid();
  }

  static String _tag(dynamic value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 256 ||
        value.startsWith('neura-local-') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      _invalid();
    }
    return value;
  }

  static XrayProfile fromJson(dynamic value) {
    final root = _map(value);
    _keys(root, {
      'remarks',
      'log',
      'dns',
      'inbounds',
      'outbounds',
      'routing',
      'observatory',
      'policy',
      'stats',
    });
    if (jsonEncode(root).length > 512 * 1024) _invalid();
    // Imported configuration may not read/write files, execute scripts or
    // install platform socket controls. Local listeners/logging are rebuilt.
    void checkNested(dynamic node) {
      if (node is Map) {
        for (final entry in node.entries) {
          if (const {
            'certificateFile',
            'keyFile',
            'file',
            'sockopt',
            'sendThrough',
            'proxySettings',
            'dialerProxy',
            'script',
            'env',
            'api',
            'metrics',
            'reverse',
            'masterKeyLog',
          }.contains(entry.key)) {
            _invalid();
          }
          checkNested(entry.value);
        }
      } else if (node is List) {
        node.forEach(checkNested);
      } else if (node is String && RegExp(r'^ext(?:-ip)?:').hasMatch(node)) {
        _invalid();
      }
    }

    checkNested(root);
    final inbounds = _list(root['inbounds']);
    final inboundTags = <String>{};
    for (final item in inbounds) {
      final inbound = _map(item);
      _keys(inbound, {
        'tag',
        'listen',
        'port',
        'protocol',
        'settings',
        'sniffing',
      });
      if (!const {'socks', 'http'}.contains(inbound['protocol'])) _invalid();
      if (!inboundTags.add(_tag(inbound['tag']))) _invalid();
      if (inbound['sniffing'] != null) {
        _keys(_map(inbound['sniffing']), {
          'enabled',
          'routeOnly',
          'destOverride',
          'metadataOnly',
          'domainsExcluded',
        });
      }
    }
    if (inbounds.isEmpty) _invalid();

    final outbounds = _list(root['outbounds']);
    final protocols = <String, String>{};
    final endpoints = <String>{};
    for (final item in outbounds) {
      final out = _map(item);
      _keys(out, {'tag', 'protocol', 'settings', 'streamSettings', 'mux'});
      final tag = _tag(out['tag']);
      if (protocols.containsKey(tag)) _invalid();
      final protocol = out['protocol'];
      if (!const {
        'vless',
        'hysteria',
        'freedom',
        'blackhole',
        'dns',
      }.contains(protocol)) {
        _invalid();
      }
      protocols[tag] = protocol as String;
      if (out['mux'] != null && _map(out['mux'])['enabled'] != false) {
        _invalid();
      }
      if (protocol != 'vless' && protocol != 'hysteria') continue;
      final stream = _map(out['streamSettings']);
      _keys(stream, {
        'network',
        'security',
        'tlsSettings',
        'realitySettings',
        'tcpSettings',
        'rawSettings',
        'xhttpSettings',
        'splithttpSettings',
        'wsSettings',
        'grpcSettings',
        'httpupgradeSettings',
        'hysteriaSettings',
        'finalmask',
      });
      if (!const {'tls', 'reality'}.contains(stream['security'])) _invalid();
      final tls = stream['tlsSettings'];
      if (tls is Map &&
          (tls['allowInsecure'] == true || tls['insecure'] == true)) {
        _invalid();
      }
      final settings = _map(out['settings']);
      final servers = protocol == 'vless'
          ? _list(settings['vnext'])
          : [settings];
      if (servers.isEmpty) _invalid();
      for (final server in servers) {
        final endpoint = _map(server);
        final address = endpoint['address'];
        final port = endpoint['port'];
        if (address is! String ||
            address.trim().isEmpty ||
            RegExp(r'[\s/\\]').hasMatch(address) ||
            port is! int ||
            port < 1 ||
            port > 65535) {
          _invalid();
        }
        endpoints.add(address);
      }
      if (protocol == 'hysteria' &&
          (settings['version'] != 2 ||
              stream['network'] != 'hysteria' ||
              stream['security'] != 'tls')) {
        _invalid();
      }
    }
    if (endpoints.isEmpty) _invalid();
    final routing = _map(root['routing']);
    _keys(routing, {'domainStrategy', 'domainMatcher', 'rules', 'balancers'});
    final balancers = _list(routing['balancers'] ?? []);
    final balancerTags = <String>{};
    for (final item in balancers) {
      final balancer = _map(item);
      _keys(balancer, {'tag', 'selector', 'strategy', 'fallbackTag'});
      if (!balancerTags.add(_tag(balancer['tag']))) _invalid();
      if (_map(balancer['strategy'])['type'] != 'leastPing' ||
          protocols[balancer['fallbackTag']] != 'blackhole') {
        _invalid();
      }
      final selectors = _list(balancer['selector']).map(_tag).toList();
      final candidates = protocols.entries
          .where((out) => selectors.any(out.key.startsWith))
          .toList();
      if (candidates.isEmpty ||
          candidates.any(
            (out) => !const {'vless', 'hysteria'}.contains(out.value),
          )) {
        _invalid();
      }
    }
    final dns = _map(root['dns']);
    _keys(dns, {
      'tag',
      'hosts',
      'servers',
      'clientIp',
      'queryStrategy',
      'disableCache',
      'disableFallback',
      'disableFallbackIfMatch',
      'enableParallelQuery',
      'serveStale',
      'serveExpiredTTL',
      'useSystemHosts',
    });
    if (_list(dns['servers']).isEmpty) _invalid();
    for (final item in _list(routing['rules'])) {
      final rule = _map(item);
      _keys(rule, {
        'type',
        'domain',
        'ip',
        'port',
        'sourcePort',
        'network',
        'source',
        'user',
        'inboundTag',
        'protocol',
        'attrs',
        'domainMatcher',
        'outboundTag',
        'balancerTag',
      });
      if (rule['type'] != 'field' ||
          (rule.containsKey('outboundTag') ==
              rule.containsKey('balancerTag'))) {
        _invalid();
      }
      if (rule.containsKey('outboundTag') &&
          !protocols.containsKey(rule['outboundTag'])) {
        _invalid();
      }
      if (rule.containsKey('balancerTag') &&
          !balancerTags.contains(rule['balancerTag'])) {
        _invalid();
      }
      for (final tag in _list(rule['inboundTag'] ?? [])) {
        if (!inboundTags.contains(tag) && tag != dns['tag']) _invalid();
      }
    }
    if (balancers.isNotEmpty) {
      final observation = _map(root['observatory']);
      _keys(observation, {
        'subjectSelector',
        'probeUrl',
        'probeInterval',
        'enableConcurrency',
      });
      final probe = Uri.tryParse(observation['probeUrl']?.toString() ?? '');
      if (probe == null ||
          probe.scheme != 'https' ||
          probe.host.isEmpty ||
          probe.userInfo.isNotEmpty ||
          observation['probeInterval'] != '60s') {
        _invalid();
      }
      final selectors = _list(
        observation['subjectSelector'],
      ).map(_tag).toList();
      for (final item in balancers) {
        final balancer = _map(item);
        for (final out in protocols.keys.where(
          (tag) => _list(
            balancer['selector'],
          ).any((prefix) => tag.startsWith(prefix as String)),
        )) {
          if (!selectors.any(out.startsWith)) _invalid();
        }
      }
    }
    final remarks = root['remarks'];
    final name = remarks is String && remarks.trim().isNotEmpty
        ? remarks.trim()
        : 'Xray';
    return XrayProfile._(
      jsonEncode(root),
      name,
      Set.unmodifiable(endpoints),
      balancers.isNotEmpty,
    );
  }
}
