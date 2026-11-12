import 'dart:convert';

import 'xray_profile.dart';

/// Only the local bridge and app-owned diagnostics change. The subscription's
/// DNS, transports, rules, candidates and fail-closed balancer stay together.
String adaptXrayProfile(
  XrayProfile profile, {
  int socksPort = 10808,
  int? forceSocksPort,
  int? apiPort,
  String? interfaceName,
  String? bindAddress,
}) {
  final config = profile.config;
  config.remove('remarks');
  config['log'] = {'loglevel': 'none', 'access': 'none', 'dnsLog': false};
  final inbounds = (config['inbounds'] as List).cast<Map<String, dynamic>>();
  final primary = inbounds.firstWhere(
    (inbound) => inbound['protocol'] == 'socks',
    orElse: () => inbounds.first,
  );
  final primaryTag = primary['tag'];
  var secondaryPort = socksPort + 2;
  for (final inbound in inbounds) {
    final isPrimary = identical(inbound, primary);
    inbound['listen'] = '127.0.0.1';
    inbound['port'] = isPrimary ? socksPort : secondaryPort++;
    if (isPrimary) inbound['protocol'] = 'socks';
    inbound['settings'] = inbound['protocol'] == 'socks'
        ? {'auth': 'noauth', 'udp': true}
        : <String, dynamic>{};
  }
  final routing = config['routing'] as Map<String, dynamic>;
  final rules = (routing['rules'] as List).cast<Map<String, dynamic>>();
  if (forceSocksPort != null) {
    inbounds.add({
      'tag': 'neura-local-force',
      'listen': '127.0.0.1',
      'port': forceSocksPort,
      'protocol': 'socks',
      'settings': {'auth': 'noauth', 'udp': true},
      if (primary['sniffing'] != null) 'sniffing': primary['sniffing'],
    });
    for (final rule in rules) {
      if ((rule['inboundTag'] as List?)?.contains(primaryTag) ?? false) {
        rule['inboundTag'] = [
          ...rule['inboundTag'] as List,
          'neura-local-force',
        ];
      }
    }
  }
  final outbounds = (config['outbounds'] as List).cast<Map<String, dynamic>>();
  if (interfaceName?.isNotEmpty == true || bindAddress?.isNotEmpty == true) {
    for (final outbound in outbounds) {
      if (const {'blackhole', 'dns'}.contains(outbound['protocol'])) continue;
      if (bindAddress?.isNotEmpty == true) {
        outbound['sendThrough'] = bindAddress;
      }
      if (interfaceName?.isNotEmpty == true) {
        final stream =
            (outbound['streamSettings'] ??= <String, dynamic>{}) as Map;
        stream['sockopt'] = {'interface': interfaceName};
      }
    }
  }
  // The mobile virtual DNS peer and the Windows SOCKS DNS bridge must terminate
  // in Xray's existing DNS service, not be sent as UDP to the virtual address.
  outbounds.add({
    'tag': 'neura-local-dns',
    'protocol': 'dns',
    'settings': {'nonIPQuery': 'reject'},
  });
  rules.insert(0, {
    'type': 'field',
    'inboundTag': inbounds.map((i) => i['tag']).toList(),
    'network': 'tcp,udp',
    'port': '53',
    'outboundTag': 'neura-local-dns',
  });
  if (profile.isAutomatic) {
    // Unmatched traffic must not default to the first candidate or freedom.
    final balancers = routing['balancers'] as List;
    rules.add({
      'type': 'field',
      'network': 'tcp,udp',
      'outboundTag': (balancers.first as Map)['fallbackTag'],
    });
  }
  if (apiPort != null) {
    config['api'] = {
      'tag': 'neura-local-api',
      'services': ['StatsService'],
    };
    config['stats'] = <String, dynamic>{};
    final policy = (config['policy'] ??= <String, dynamic>{}) as Map;
    policy['system'] = {
      ...?policy['system'] as Map?,
      'statsInboundUplink': true,
      'statsInboundDownlink': true,
      'statsOutboundUplink': true,
      'statsOutboundDownlink': true,
    };
    inbounds.add({
      'tag': 'neura-local-api-in',
      'listen': '127.0.0.1',
      'port': apiPort,
      'protocol': 'dokodemo-door',
      'settings': {'address': '127.0.0.1'},
    });
    rules.insert(0, {
      'type': 'field',
      'inboundTag': ['neura-local-api-in'],
      'outboundTag': 'neura-local-api',
    });
  }
  config['inbounds'] = inbounds;
  config['outbounds'] = outbounds;
  routing['rules'] = rules;
  return jsonEncode(config);
}
