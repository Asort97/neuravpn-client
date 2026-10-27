import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/qr_import.dart';

void main() {
  test('accepts subscription URLs and preserves encoded credentials', () {
    const url = 'https://example.com/sub/a%2Fb?token=x%2By';
    expect(parseQrImport('  $url\n'), url);
    expect(parseQrImport('http://192.168.1.2:8080/sub'), isNotNull);
  });

  test('accepts secure VLESS TCP and XHTTP without modifying parameters', () {
    for (final transport in ['tcp', 'xhttp']) {
      final value =
          'vless://11111111-1111-1111-1111-111111111111@'
          'example.com:443?security=reality&type=$transport&'
          'sni=example.com&pbk=test&sid=abcd#My%20server';
      expect(parseQrImport(value), value);
    }
  });

  test('rejects unrelated, malformed and oversized QR data without throwing', () {
    for (final input in <String?>[
      null,
      '',
      'hello',
      'https://',
      'https://example.com:abc/sub',
      'https://example.com:99999/sub',
      'https://example.com:0/sub',
      'https://user:pass@example.com/sub',
      'file:///etc/passwd',
      'javascript:alert(1)',
      'tg://resolve?domain=test',
      'https://example.com/a\nb',
      'https://example.com/\u0000',
      'vless://bad@example.com:443?security=reality',
      'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=none',
      'https://example.com/${'x' * 8192}',
    ]) {
      expect(parseQrImport(input), isNull);
    }
  });
}
