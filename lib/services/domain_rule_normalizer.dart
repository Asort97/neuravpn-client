import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:public_suffix/public_suffix.dart';

class DomainRuleNormalizer {
  static const String defaultRulesAssetPath =
      'assets/public_suffix/public_suffix_list.dat';

  static Future<void>? _bootstrapFuture;

  static const List<String> _explicitPrefixes = <String>[
    'geosite:',
    'domain-suffix:',
    'domain_suffix:',
    'suffix:',
    'domain-keyword:',
    'domain_keyword:',
    'keyword:',
    'domain-full:',
    'domain_full:',
    'full:',
    'domain:',
    'domain-regex:',
    'domain_regex:',
    'regexp:',
    'regex:',
  ];

  static Future<void> initializeDefaultRules({
    AssetBundle? bundle,
    String assetPath = defaultRulesAssetPath,
  }) async {
    if (DefaultSuffixRules.hasInitialised()) return;

    _bootstrapFuture ??= () async {
      try {
        final sourceBundle = bundle ?? rootBundle;
        final rules = await sourceBundle.loadString(assetPath);
        DefaultSuffixRules.initFromString(rules);
      } catch (error, stackTrace) {
        debugPrint(
          'DomainRuleNormalizer: failed to load PSL rules from $assetPath: $error',
        );
        debugPrintStack(stackTrace: stackTrace);
      } finally {
        if (!DefaultSuffixRules.hasInitialised()) {
          _bootstrapFuture = null;
        }
      }
    }();

    await _bootstrapFuture;
  }

  List<String> normalizeForConnection({
    required String mode,
    required List<String> entries,
    void Function(String message)? onDebug,
  }) {
    if (entries.isEmpty) {
      return const <String>[];
    }

    final sanitizedEntries = <String>[];
    for (final raw in entries) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      final sanitized = sanitizeDomainEntry(value);
      if (sanitized != value) {
        onDebug?.call('domain sanitized: $value -> $sanitized');
      }
      sanitizedEntries.add(sanitized);
    }

    final shouldLiftToRegistrable = mode == 'whitelist' || mode == 'blacklist';
    if (!shouldLiftToRegistrable) {
      return sanitizedEntries;
    }

    final result = LinkedHashSet<String>();
    var reportedMissingRules = false;

    for (final value in sanitizedEntries) {
      final normalized = _normalizeDomainEntry(
        value,
        onMissingRules: () {
          if (reportedMissingRules) return;
          reportedMissingRules = true;
          onDebug?.call('psl unavailable, keeping original domain: $value');
        },
      );

      if (normalized != value) {
        onDebug?.call('domain normalized: $value -> $normalized');
      }
      result.add(normalized);
    }

    return result.toList(growable: false);
  }

  String sanitizeDomainEntry(String entry) {
    final value = entry.trim();
    if (value.isEmpty) return value;
    if (_shouldKeepRaw(value)) return value;

    String? host = _tryExtractHostFromUrl(value);
    host ??= _tryExtractHostFromFallback(value);
    if (host == null || host.isEmpty) return value;
    if (_looksLikeIpv4(host) || _looksLikeIpv6(host)) return host;
    if (!_looksLikePlainHost(host)) return value;
    return host;
  }

  String _normalizeDomainEntry(
    String entry, {
    required VoidCallback onMissingRules,
  }) {
    if (_shouldSkip(entry)) return entry;

    final host = _toPlainHost(entry);
    if (host == null) return entry;

    if (!DefaultSuffixRules.hasInitialised()) {
      onMissingRules();
      return entry;
    }

    final parsed = PublicSuffix.fromString(
      'https://$host',
      leniency: Leniency.allowAll,
    );
    final registrable = (parsed?.icannDomain ?? parsed?.domain)?.toLowerCase();
    if (registrable == null || registrable.isEmpty) return entry;
    if (registrable == host) return entry;
    if (!_looksLikePlainHost(registrable)) return entry;
    return registrable;
  }

  bool _shouldSkip(String entry) {
    return _shouldKeepRaw(entry);
  }

  bool _shouldKeepRaw(String entry) {
    final lower = entry.toLowerCase();
    if (entry.contains('*')) return true;
    if (_looksLikeIpv4(entry) ||
        _looksLikeIpv6(entry) ||
        _looksLikeCidr(entry)) {
      return true;
    }
    for (final prefix in _explicitPrefixes) {
      if (lower.startsWith(prefix)) return true;
    }
    return false;
  }

  String? _toPlainHost(String value) {
    var host = value.trim().toLowerCase();
    if (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    if (!_looksLikePlainHost(host)) return null;
    return host;
  }

  String? _tryExtractHostFromUrl(String value) {
    final directUri = Uri.tryParse(value);
    if (directUri != null &&
        directUri.hasAuthority &&
        directUri.host.isNotEmpty) {
      return _normalizeExtractedHost(directUri.host);
    }
    return null;
  }

  String? _tryExtractHostFromFallback(String value) {
    if (value.contains('://')) {
      return null;
    }
    final fallback = Uri.tryParse('https://$value');
    if (fallback == null || fallback.host.isEmpty) {
      return null;
    }
    return _normalizeExtractedHost(fallback.host);
  }

  String _normalizeExtractedHost(String host) {
    var normalized = host.trim().toLowerCase();
    if (normalized.endsWith('.')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  bool _looksLikePlainHost(String value) {
    if (value.isEmpty || !value.contains('.')) return false;
    if (value.contains(' ') || value.contains('/') || value.contains(':')) {
      return false;
    }
    if (value.startsWith('.') || value.endsWith('.')) return false;
    return RegExp(r'^[a-z0-9.-]+$').hasMatch(value);
  }

  bool _looksLikeIpv4(String value) {
    final ipv4 = RegExp(
      r'^(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}$',
    );
    return ipv4.hasMatch(value);
  }

  bool _looksLikeIpv6(String value) {
    if (!value.contains(':')) return false;
    return RegExp(r'^[0-9a-fA-F:]+$').hasMatch(value);
  }

  bool _looksLikeCidr(String value) {
    return RegExp(r'^([0-9a-fA-F:.]+)/\d{1,3}$').hasMatch(value);
  }

  @visibleForTesting
  static void resetForTesting() {
    DefaultSuffixRules.dispose();
    _bootstrapFuture = null;
  }
}
