import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/main.dart';

void main() {
  test('extracts encoded VLESS from neuravpn import link', () {
    const expectedUri =
        'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&type=tcp&sni=example.com#tag';
    final encodedUri = Uri.encodeComponent(expectedUri);

    final extracted = extractImportedVlessFromLaunchArgs([
      'neuravpn://import?v=$encodedUri',
    ]);

    expect(extracted, expectedUri);
  });

  test('ignores unrelated launch arguments', () {
    final extracted = extractImportedVlessFromLaunchArgs([
      '--verbose',
      'https://example.com',
    ]);

    expect(extracted, isNull);
  });
}
