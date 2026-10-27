import 'hysteria2_parser.dart';
import 'proxy_link.dart';
import 'vless_parser.dart';
export 'hysteria2_parser.dart';
export 'proxy_link.dart';
export 'vless_parser.dart';

bool isProxyUri(String raw) => RegExp(
  r'^(vless|hysteria2|hy2)://',
  caseSensitive: false,
).hasMatch(raw.trim());

ProxyLink? parseProxyUri(String raw) =>
    parseVlessUri(raw) ?? parseHysteria2Uri(raw);

String? proxyValidationError(ProxyLink link) {
  if (link is VlessLink) {
    return isSecureVlessLink(link) ? null : 'VLESS требует TLS или Reality.';
  }
  if (link is Hysteria2Link) {
    final obfs = link.params['obfs'];
    if (obfs != null && obfs.isNotEmpty && obfs != 'salamander') {
      return 'Этот режим маскировки Hysteria 2 пока не поддерживается. Используйте Salamander.';
    }
    if (obfs == 'salamander' && (link.params['obfs-password'] ?? '').isEmpty) {
      return 'В ссылке Hysteria 2 отсутствует пароль Salamander.';
    }
    if ((link.params['ech'] ?? '').isNotEmpty) {
      return 'Импорт ECH для Hysteria 2 пока не поддерживается.';
    }
    if (const ['1', 'true'].contains(link.params['insecure']) &&
        link.certificatePin == null) {
      return 'Hysteria 2: ядро не поддерживает insecure=1 без pinSHA256. Нужен доверенный сертификат или его SHA-256 отпечаток.';
    }
    return null;
  }
  return 'Протокол не поддерживается.';
}

bool isSecureProxyUri(String raw) {
  final link = parseProxyUri(raw);
  return link != null && proxyValidationError(link) == null;
}

String proxyImportError(String raw) {
  final link = parseProxyUri(raw);
  return link == null
      ? 'Неверная ссылка. Поддерживаются VLESS и Hysteria 2.'
      : proxyValidationError(link) ?? 'Не удалось добавить профиль.';
}
