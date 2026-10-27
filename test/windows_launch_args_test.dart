import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/main.dart';

void main() {
  test('extracts direct and wrapped Hysteria 2 links', () {
    for (final scheme in ['hy2', 'hysteria2']) {
      final uri =
          '$scheme://password@example.com:443,8443?sni=example.com#Node';
      expect(extractImportedVlessFromLaunchArgs([uri]), uri);
      expect(
        extractImportedVlessFromLaunchArgs([
          'neuravpn://import?v=${Uri.encodeComponent(uri)}',
        ]),
        uri,
      );
    }
  });

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

  test('extracts encoded subscription URL from neuravpn import link', () {
    const expectedUrl =
        'https://sub.staticdeliverycdn.com:2096/s-39fj3r9f3j/fd6abff9-7831-401e-91a5-3c334fbc6c60';
    final encodedUrl = Uri.encodeComponent(expectedUrl);

    final extracted = extractImportedVlessFromLaunchArgs([
      'neuravpn://import?v=$encodedUrl',
    ]);

    expect(extracted, expectedUrl);
  });

  test('extracts subscription URL from website wrapper link', () {
    const expectedUrl =
        'https://sub.staticdeliverycdn.com:2096/s-39fj3r9f3j/fd6abff9-7831-401e-91a5-3c334fbc6c60';
    final encodedUrl = Uri.encodeComponent(expectedUrl);

    final extracted = extractImportedVlessFromLaunchArgs([
      'https://asort97.github.io/neuravpn-site/?open=1&v=$encodedUrl&cb=1',
    ]);

    expect(extracted, expectedUrl);
  });

  test('extracts supported Android subscription app link directly', () {
    const expectedUrl =
        'https://webhook.staticdeliverycdn.com/merged-sub/123/token';

    final extracted = extractImportedVlessFromLaunchArgs([expectedUrl]);

    expect(extracted, expectedUrl);
  });
}
