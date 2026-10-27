import '../vless/proxy_parser.dart';

/// QR contents are untrusted. Never open arbitrary schemes or execute a link.
String? parseQrImport(String? raw) {
  if (raw == null || raw.length > 8192) return null;
  final text = raw.trim();
  if (text.isEmpty || RegExp(r'[\x00-\x20\x7f]').hasMatch(text)) {
    return null;
  }
  if (isProxyUri(text)) {
    return isSecureProxyUri(text) ? text : null;
  }
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.userInfo.isEmpty &&
      uri.port > 0 &&
      uri.port <= 65535) {
    return text;
  }
  return null;
}
