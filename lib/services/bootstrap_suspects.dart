import 'package:flutter/services.dart';

class BootstrapSuspects {
  BootstrapSuspects(this._suffixes);

  final Set<String> _suffixes;

  static Future<BootstrapSuspects> load() async {
    final includes = <String>[
      'assets/zapret/lists/list-general.txt',
      'assets/zapret/lists/list-google.txt',
    ];
    final excludes = <String>[
      'assets/zapret/lists/list-exclude.txt',
      'assets/zapret/lists/ipset-exclude.txt',
    ];

    final includeSet = <String>{};
    for (final path in includes) {
      includeSet.addAll(await _loadDomains(path));
    }

    final excludeSet = <String>{};
    for (final path in excludes) {
      excludeSet.addAll(await _loadDomains(path));
    }

    includeSet.removeWhere((entry) => excludeSet.contains(entry));

    return BootstrapSuspects(includeSet);
  }

  bool isSuspect(String domain) {
    final value = domain.toLowerCase();
    if (_suffixes.contains(value)) return true;
    for (final suffix in _suffixes) {
      if (value == suffix) return true;
      if (value.endsWith('.$suffix')) return true;
    }
    return false;
  }

  static Future<List<String>> _loadDomains(String assetPath) async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      final lines = raw.split(RegExp(r'\r?\n'));
      return lines
          .map(_normalizeLine)
          .where((line) => line.isNotEmpty)
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }

  static String _normalizeLine(String line) {
    var value = line.trim();
    if (value.isEmpty) return '';
    if (value.startsWith('#') || value.startsWith('//')) return '';
    if (value.startsWith('domain:')) {
      value = value.substring('domain:'.length);
    }
    if (value.startsWith('.')) {
      value = value.substring(1);
    }
    return value.trim().toLowerCase();
  }
}