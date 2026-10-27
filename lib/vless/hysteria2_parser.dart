import 'proxy_link.dart';

class Hysteria2Link extends ProxyLink {
  Hysteria2Link({
    required this.host,
    required this.port,
    required this.auth,
    required this.params,
    this.tag,
    this.hoppingPorts,
  });

  @override
  final String host;
  @override
  final int port;
  final String auth;
  @override
  final Map<String, String> params;
  @override
  final String? tag;
  final String? hoppingPorts;
  @override
  String get protocolLabel => 'Hysteria 2';
  @override
  String get security => 'tls';
  @override
  String get type => 'quic';
  String? get certificatePin => params['pinSHA256'] ?? params['pinsha256'];
}

Hysteria2Link? parseHysteria2Uri(String raw) {
  final text = raw.trim();
  if (!RegExp(r'^(hysteria2|hy2)://', caseSensitive: false).hasMatch(text) ||
      RegExp(r'[\x00-\x20\x7f]').hasMatch(text)) {
    return null;
  }
  try {
    // Reject malformed escapes before Uri normalizes stray percent signs.
    Uri.decodeComponent(text);
    // Uri only accepts one numeric port. Normalize the authority before parsing
    // the standard Hysteria port-list extension, including bracketed IPv6.
    final schemeEnd = text.indexOf('://') + 3;
    final end = text.indexOf(RegExp(r'[/#?]'), schemeEnd);
    final authorityEnd = end < 0 ? text.length : end;
    final authority = text.substring(schemeEnd, authorityEnd);
    final at = authority.lastIndexOf('@');
    final endpoint = authority.substring(at + 1);
    final colon = endpoint.startsWith('[')
        ? (endpoint.contains(']') && endpoint.length > endpoint.indexOf(']') + 1
              ? endpoint.indexOf(']') + 1
              : -1)
        : endpoint.indexOf(':');
    final ports = colon < 0 ? '443' : endpoint.substring(colon + 1);
    if (colon >= 0 && endpoint[colon] != ':') return null;
    if (!_validPorts(ports)) return null;
    final port = int.parse(ports.split(',').first.split('-').first);
    final hostPart = colon < 0 ? endpoint : endpoint.substring(0, colon);
    final userPart = at < 0 ? '' : '${authority.substring(0, at)}@';
    final uri = Uri.parse(
      'hysteria2://$userPart$hostPart:$port${text.substring(authorityEnd)}',
    );
    if (uri.host.isEmpty || (uri.path.isNotEmpty && uri.path != '/')) {
      return null;
    }
    if (uri.queryParametersAll.values.any((values) => values.length != 1)) {
      return null;
    }
    final params = Map<String, String>.unmodifiable(uri.queryParameters);
    final hopping = params['mport'] ?? ports;
    if (!_validPorts(hopping)) return null;
    final insecure = params['insecure'];
    if (insecure != null &&
        !const ['0', '1', 'true', 'false'].contains(insecure)) {
      return null;
    }
    final pin = params['pinSHA256'] ?? params['pinsha256'];
    if (pin != null &&
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(pin.replaceAll(':', ''))) {
      return null;
    }
    return Hysteria2Link(
      host: uri.host.startsWith('[')
          ? uri.host.substring(1, uri.host.length - 1)
          : uri.host,
      port: port,
      auth: Uri.decodeComponent(uri.userInfo),
      params: params,
      tag: uri.fragment.isEmpty ? null : Uri.decodeComponent(uri.fragment),
      hoppingPorts:
          hopping.contains(',') ||
              hopping.contains('-') ||
              params.containsKey('mport')
          ? hopping
          : null,
    );
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

bool _validPorts(String ports) {
  if (ports.isEmpty) return false;
  for (final segment in ports.split(',')) {
    if (!RegExp(r'^\d+(?:-\d+)?$').hasMatch(segment)) return false;
    final range = segment.split('-').map(int.tryParse).toList();
    if (range.any((port) => port == null || port < 1 || port > 65535)) {
      return false;
    }
    if (range.length == 2 && range.first! > range.last!) return false;
  }
  return true;
}
