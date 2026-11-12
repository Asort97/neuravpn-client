import 'package:intl/intl.dart';
import 'dart:math' as math;

/// Модель VPN подписки (3X-UI)
class VpnSubscription {
  final String id; // Уникальный идентификатор (UUID или random)
  final String name; // Название подписки
  final String url; // URL подписки
  final List<String> profiles; // Список VLESS URI профилей
  final int selectedIndex; // Индекс выбранного профиля (0 = первый)
  final DateTime lastUpdated; // Время последнего обновления
  final String? error; // Ошибка при последнем обновлении

  VpnSubscription({
    String? id,
    required this.name,
    required this.url,
    required this.profiles,
    this.selectedIndex = 0,
    DateTime? lastUpdated,
    this.error,
  })  : id = id ?? _generateId(),
        lastUpdated = lastUpdated ?? DateTime.now();

  /// Генерировать случайный ID
  static String _generateId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = math.Random();
    return List.generate(16, (index) => chars[random.nextInt(chars.length)]).join();
  }

  /// Получить выбранный профиль (VLESS URI)
  String? get selectedProfile {
    if (profiles.isEmpty || selectedIndex >= profiles.length) return null;
    return profiles[selectedIndex];
  }

  /// Количество доступных профилей
  int get profileCount => profiles.length;

  /// Форматированное время последнего обновления
  String get formattedLastUpdate {
    final format = DateFormat('dd.MM.yyyy HH:mm:ss', 'ru_RU');
    return format.format(lastUpdated);
  }

  /// Скопировать с изменениями
  VpnSubscription copyWith({
    String? id,
    String? name,
    String? url,
    List<String>? profiles,
    int? selectedIndex,
    DateTime? lastUpdated,
    String? error,
  }) {
    return VpnSubscription(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      profiles: profiles ?? this.profiles,
      selectedIndex: selectedIndex ?? this.selectedIndex,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      error: error ?? (profiles != null ? null : this.error),
    );
  }

  /// Сериализация в JSON для хранения
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'profiles': profiles,
    'selectedIndex': selectedIndex,
    'lastUpdated': lastUpdated.toIso8601String(),
    'error': error,
  };

  /// Десериализация из JSON
  factory VpnSubscription.fromJson(Map<String, dynamic> json) {
    return VpnSubscription(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Unnamed',
      url: json['url'] as String? ?? '',
      profiles: List<String>.from(json['profiles'] as List? ?? []),
      selectedIndex: json['selectedIndex'] as int? ?? 0,
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.parse(json['lastUpdated'] as String)
          : DateTime.now(),
      error: json['error'] as String?,
    );
  }

  @override
  String toString() => 'VpnSubscription($name, $profileCount profiles)';
}
