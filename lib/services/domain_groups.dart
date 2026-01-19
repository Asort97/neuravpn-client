import 'connectivity_targets.dart';

class DomainGroup {
  const DomainGroup({required this.id, required this.domains});

  final String id;
  final Set<String> domains;
}

class DomainGroupResolver {
  DomainGroupResolver(Iterable<DomainGroup> groups)
      : _groups = {for (final group in groups) group.id: group},
        _exact = <String, String>{},
        _suffix = <String, String>{} {
    for (final group in groups) {
      for (final raw in group.domains) {
        final normalized = _normalizeDomain(raw);
        if (normalized.isEmpty) continue;
        _exact.putIfAbsent(normalized, () => group.id);
        _suffix.putIfAbsent(normalized, () => group.id);
      }
    }
  }

  final Map<String, DomainGroup> _groups;
  final Map<String, String> _exact;
  final Map<String, String> _suffix;

  Iterable<DomainGroup> get groups => _groups.values;

  DomainGroup? groupById(String id) => _groups[id];

  String? resolveGroupId(String domain) {
    final normalized = _normalizeDomain(domain);
    if (normalized.isEmpty) return null;
    final exact = _exact[normalized];
    if (exact != null) return exact;

    for (final entry in _suffix.entries) {
      if (normalized.endsWith('.${entry.key}')) {
        return entry.value;
      }
    }
    return null;
  }

  static String _normalizeDomain(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\.+$'), '');
  }
}

List<DomainGroup> buildDefaultDomainGroups() {
  final targets = buildDefaultConnectivityTargets();
  final grouped = <String, Set<String>>{};
  for (final target in targets) {
    grouped.putIfAbsent(target.category, () => <String>{}).add(target.domain);
  }
  return grouped.entries
      .map((entry) => DomainGroup(id: entry.key, domains: entry.value))
      .toList();
}
