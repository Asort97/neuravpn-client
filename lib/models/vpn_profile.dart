import 'dart:convert';

class VpnProfile {
  VpnProfile({required this.name, required this.uri});

  final String name;
  final String uri;

  Map<String, dynamic> toJson() => {'name': name, 'uri': uri};

  static VpnProfile fromJson(Map<String, dynamic> json) => VpnProfile(
        name: json['name'] as String? ?? 'Profile',
        uri: json['uri'] as String? ?? '',
      );

  static List<VpnProfile> listFromJsonString(String? payload) {
    if (payload == null || payload.isEmpty) return [];
    try {
      final decoded = jsonDecode(payload);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(VpnProfile.fromJson)
            .where((profile) => profile.uri.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  static String listToJsonString(List<VpnProfile> profiles) {
    final data = profiles.map((p) => p.toJson()).toList();
    return jsonEncode(data);
  }
}
