import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/update_service.dart';

GithubReleaseInfo _release(String tag) {
  return GithubReleaseInfo(
    tag: tag,
    name: 'neuravpn-client $tag',
    body: '',
    htmlUrl: Uri.parse(
      'https://github.com/Asort97/neuravpn-client/releases/tag/$tag',
    ),
    isPrerelease: false,
    publishedAt: null,
  );
}

void main() {
  group('GithubUpdateService version comparison', () {
    final service = GithubUpdateService();

    test('recognizes the existing v-dot release tag format', () {
      final result = service.compareVersions(
        currentVersion: '1.0.7',
        latest: _release('v.1.0.8'),
      );

      expect(result, isNotNull);
      expect(result!.latestVersion, '1.0.8');
      expect(result.isUpdateAvailable, isTrue);
    });

    test('recognizes a conventional v-prefixed release tag', () {
      final result = service.compareVersions(
        currentVersion: '1.0.7+7',
        latest: _release('v1.0.8'),
      );

      expect(result, isNotNull);
      expect(result!.latestVersion, '1.0.8');
      expect(result.isUpdateAvailable, isTrue);
    });

    test('does not offer the installed release again', () {
      final result = service.compareVersions(
        currentVersion: '1.0.8',
        latest: _release('neuravpn-v.1.0.8'),
      );

      expect(result, isNotNull);
      expect(result!.isUpdateAvailable, isFalse);
    });
  });
}
