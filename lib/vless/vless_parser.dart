import 'dart:core';

/// Модель разобранной VLESS ссылки
class VlessLink {
  final String uuid;
  final String host;
  final int port;
  final Map<String, String> params;
  final String? tag;

  VlessLink({
    required this.uuid,
    required this.host,
    required this.port,
    required this.params,
    this.tag,
  });

  // Вспомогательные геттеры
  String? get security => params['security'];
  String? get flow => params['flow'];
  String? get sni => params['sni'];
  String? get type => params['type'];
  bool get isReality => security == 'reality';
  bool get isTls => security == 'tls' || isReality;
}

bool isSecureVlessLink(VlessLink link) {
  final security = (link.security ?? '').toLowerCase().trim();
  return security == 'tls' || security == 'reality';
}

bool isSecureVlessUri(String raw) {
  final parsed = parseVlessUri(raw);
  if (parsed == null) {
    return false;
  }
  return isSecureVlessLink(parsed);
}

/// Парсер VLESS URI с валидацией
/// Формат: vless://<uuid>@<host>:<port>?param1=...&param2=...#tag
VlessLink? parseVlessUri(String raw) {
  raw = raw.trim();
  if (raw.isEmpty) return null;
  if (!raw.startsWith('vless://')) return null;

  // Базовая валидация длины
  if (raw.length < 50) return null;

  final withoutScheme = raw.substring('vless://'.length);
  // Отделяем #tag если есть
  String? tag;
  String mainPart = withoutScheme;
  final hashIndex = withoutScheme.indexOf('#');
  if (hashIndex != -1) {
    final rawTag = withoutScheme.substring(hashIndex + 1).trim();
    tag = _decodeComponentOrRaw(rawTag);
    mainPart = withoutScheme.substring(0, hashIndex);
  }

  // Делим на часть до ? и query
  String basePart = mainPart;
  String? queryPart;
  final qIndex = mainPart.indexOf('?');
  if (qIndex != -1) {
    basePart = mainPart.substring(0, qIndex);
    queryPart = mainPart.substring(qIndex + 1);
  }

  // uuid@host:port
  final atIndex = basePart.indexOf('@');
  if (atIndex == -1) return null;
  final uuid = basePart.substring(0, atIndex);
  final hostPort = basePart.substring(atIndex + 1);

  // Валидация UUID (базовая)
  if (uuid.isEmpty || uuid.length < 32) return null;
  final uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  if (!uuidRegex.hasMatch(uuid)) return null;

  String host;
  String portStr;
  if (hostPort.startsWith('[')) {
    final closingBracket = hostPort.indexOf(']');
    if (closingBracket <= 1 || closingBracket + 2 > hostPort.length) {
      return null;
    }
    if (hostPort[closingBracket + 1] != ':') return null;
    host = hostPort.substring(1, closingBracket);
    portStr = hostPort.substring(closingBracket + 2);
  } else {
    final colonIndex = hostPort.lastIndexOf(':');
    if (colonIndex == -1) return null;
    host = hostPort.substring(0, colonIndex);
    portStr = hostPort.substring(colonIndex + 1);
  }
  final port = int.tryParse(portStr);
  if (port == null || port < 1 || port > 65535) return null;

  // Валидация хоста
  if (host.isEmpty) return null;

  final params = <String, String>{};
  if (queryPart != null && queryPart.isNotEmpty) {
    for (final segment in queryPart.split('&')) {
      if (segment.isEmpty) continue;
      final eqIndex = segment.indexOf('=');
      if (eqIndex == -1) {
        params[_decodeComponentOrRaw(segment)] = '';
      } else {
        final key = _decodeComponentOrRaw(segment.substring(0, eqIndex));
        final value = _decodeComponentOrRaw(segment.substring(eqIndex + 1));
        params[key] = value;
      }
    }
  }

  return VlessLink(
    uuid: uuid,
    host: host,
    port: port,
    params: params,
    tag: tag,
  );
}

String _decodeComponentOrRaw(String value) {
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return value;
  }
}
