class ServiceSessionBuilder {
  final Map<String, Set<String>> _clusters = {};

  String registerDomain(String domain) {
    final normalized = _normalize(domain);
    if (normalized.isEmpty) return 'unknown';
    final clusterId = _etldPlusOne(normalized);
    final set = _clusters.putIfAbsent(clusterId, () => <String>{});
    set.add(normalized);
    return clusterId;
  }

  Set<String> domainsForCluster(String clusterId) {
    return _clusters[clusterId] ?? const <String>{};
  }

  static String _normalize(String domain) {
    var value = domain.trim().toLowerCase();
    if (value.endsWith('.')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static String _etldPlusOne(String domain) {
    final parts = domain.split('.');
    if (parts.length <= 2) return domain;
    return parts.sublist(parts.length - 2).join('.');
  }
}
