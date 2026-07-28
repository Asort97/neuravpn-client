import 'dart:convert';

import 'package:http/http.dart' as http;

class GithubReleaseInfo {
  const GithubReleaseInfo({
    required this.tag,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.isPrerelease,
    required this.publishedAt,
    this.assets = const [],
  });

  final String tag;
  final String name;
  final String body;
  final Uri htmlUrl;
  final bool isPrerelease;
  final DateTime? publishedAt;
  final List<GithubReleaseAsset> assets;
}

class GithubReleaseAsset {
  const GithubReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  final String name;
  final Uri downloadUrl;
  final int size;
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.latestTag,
    required this.releaseUrl,
    required this.releaseNotes,
    required this.isUpdateAvailable,
    this.assets = const [],
  });

  final String currentVersion;
  final String latestVersion;
  final String latestTag;
  final Uri releaseUrl;
  final String releaseNotes;
  final bool isUpdateAvailable;
  final List<GithubReleaseAsset> assets;
}

class GithubUpdateService {
  GithubUpdateService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<GithubReleaseInfo?> fetchLatestRelease(
    String owner,
    String repo, {
    bool includePrerelease = false,
  }) async {
    final uri = Uri.https('api.github.com', '/repos/$owner/$repo/releases');
    final response = await _client
        .get(
          uri,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'neuravpn',
          },
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return null;

    Map<String, dynamic>? pick;
    for (final item in decoded) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final prerelease = map['prerelease'] == true;
      if (!includePrerelease && prerelease) continue;
      pick = map;
      break;
    }
    if (pick == null) return null;

    final tag = (pick['tag_name'] as String?)?.trim() ?? '';
    final name = (pick['name'] as String?)?.trim() ?? '';
    final body = (pick['body'] as String?)?.trim() ?? '';
    final html = (pick['html_url'] as String?)?.trim() ?? '';
    if (tag.isEmpty || html.isEmpty) return null;
    final publishedAtRaw = (pick['published_at'] as String?)?.trim();
    DateTime? publishedAt;
    if (publishedAtRaw != null && publishedAtRaw.isNotEmpty) {
      publishedAt = DateTime.tryParse(publishedAtRaw);
    }

    final rawAssets = pick['assets'];
    final assets = <GithubReleaseAsset>[];
    if (rawAssets is List) {
      for (final a in rawAssets) {
        if (a is! Map) continue;
        final assetName = (a['name'] as String?)?.trim() ?? '';
        final url = (a['browser_download_url'] as String?)?.trim() ?? '';
        final size = a['size'] as int? ?? 0;
        if (assetName.isNotEmpty && url.isNotEmpty) {
          assets.add(
            GithubReleaseAsset(
              name: assetName,
              downloadUrl: Uri.parse(url),
              size: size,
            ),
          );
        }
      }
    }

    return GithubReleaseInfo(
      tag: tag,
      name: name,
      body: body,
      htmlUrl: Uri.parse(html),
      isPrerelease: pick['prerelease'] == true,
      publishedAt: publishedAt,
      assets: assets,
    );
  }

  UpdateCheckResult? compareVersions({
    required String currentVersion,
    required GithubReleaseInfo latest,
  }) {
    final latestVersion = _normalizeVersion(latest.tag);
    if (latestVersion.isEmpty) return null;
    final currentNormalized = _normalizeVersion(currentVersion);
    if (currentNormalized.isEmpty) return null;

    final isNewer = _isNewerVersion(latestVersion, currentNormalized);
    return UpdateCheckResult(
      currentVersion: currentNormalized,
      latestVersion: latestVersion,
      latestTag: latest.tag,
      releaseUrl: latest.htmlUrl,
      releaseNotes: latest.body,
      isUpdateAvailable: isNewer,
      assets: latest.assets,
    );
  }

  String _normalizeVersion(String raw) {
    final match = RegExp(r'\d+(?:\.\d+)+').firstMatch(raw.trim());
    if (match == null) return '';
    final v = match.group(0)!;
    final parts = v.split('.');
    if (parts.length < 2) return '';
    for (final p in parts) {
      if (int.tryParse(p) == null) return '';
    }
    return v;
  }

  bool _isNewerVersion(String a, String b) {
    final ap = _parse(a);
    final bp = _parse(b);
    final maxLen = ap.length > bp.length ? ap.length : bp.length;
    for (var i = 0; i < maxLen; i++) {
      final av = i < ap.length ? ap[i] : 0;
      final bv = i < bp.length ? bp[i] : 0;
      if (av != bv) return av > bv;
    }
    return false;
  }

  List<int> _parse(String v) {
    return v.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  }
}
