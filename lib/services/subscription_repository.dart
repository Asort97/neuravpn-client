import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_subscription.dart';

class SubscriptionRepository {
  static const String _storageKey = 'vpn_subscriptions_list';
  static const String _selectedSubscriptionKey = 'selected_subscription_id';

  late SharedPreferences _prefs;
  bool _initialized = false;

  /// Инициализировать репозиторий
  Future<void> initialize() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  /// Получить все подписки
  Future<List<VpnSubscription>> getAllSubscriptions() async {
    await initialize();
    final stored = _prefs.getStringList(_storageKey) ?? [];
    return stored
        .map((json) {
          try {
            return VpnSubscription.fromJson(jsonDecode(json));
          } catch (_) {
            return null;
          }
        })
        .whereType<VpnSubscription>()
        .toList();
  }

  /// Получить подписку по ID
  Future<VpnSubscription?> getSubscription(String id) async {
    final all = await getAllSubscriptions();
    try {
      return all.firstWhere((sub) => sub.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Добавить подписку
  Future<bool> addSubscription(VpnSubscription subscription) async {
    await initialize();
    try {
      final all = await getAllSubscriptions();
      // Проверяем что такая подписка ещё не добавлена
      final normalizedUrl = subscription.url.trim();
      if (normalizedUrl.isEmpty) return false;
      final existingIndex = all.indexWhere(
        (sub) => sub.url.trim() == normalizedUrl,
      );
      if (existingIndex != -1) {
        final existing = all[existingIndex];
        all[existingIndex] = subscription.copyWith(id: existing.id);
      } else {
        all.add(subscription);
      }
      await _saveAll(all);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Обновить подписку
  Future<bool> updateSubscription(VpnSubscription subscription) async {
    await initialize();
    try {
      final all = await getAllSubscriptions();
      final index = all.indexWhere((sub) => sub.id == subscription.id);
      if (index == -1) return false;
      all[index] = subscription;
      await _saveAll(all);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Удалить подписку
  /// Add or replace a subscription matching by URL (recovers from stale/ghost entries).
  Future<bool> upsertSubscriptionByUrl(VpnSubscription subscription) async {
    await initialize();
    try {
      final normalizedUrl = subscription.url.trim();
      if (normalizedUrl.isEmpty) return false;

      final all = await getAllSubscriptions();
      final index = all.indexWhere((sub) => sub.url.trim() == normalizedUrl);
      if (index == -1) {
        all.add(subscription);
        await _saveAll(all);
        return true;
      }

      final existing = all[index];
      all[index] = subscription.copyWith(id: existing.id);
      await _saveAll(all);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteSubscriptionByUrl(String url) async {
    await initialize();
    try {
      final normalizedUrl = url.trim();
      if (normalizedUrl.isEmpty) return false;

      final all = await getAllSubscriptions();
      all.removeWhere((sub) => sub.url.trim() == normalizedUrl);
      await _saveAll(all);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteSubscription(String id) async {
    await initialize();
    try {
      final all = await getAllSubscriptions();
      all.removeWhere((sub) => sub.id == id);
      await _saveAll(all);

      // Если это была выбранная подписка, очищаем выбор
      final selected = await getSelectedSubscriptionId();
      if (selected == id) {
        await clearSelectedSubscription();
      }
      if (selected != null && selected.isNotEmpty) {
        if (await getSubscription(selected) == null) {
          await clearSelectedSubscription();
        }
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  /// Получить выбранную подписку (ID)
  Future<String?> getSelectedSubscriptionId() async {
    await initialize();
    return _prefs.getString(_selectedSubscriptionKey);
  }

  /// Установить выбранную подписку
  Future<bool> setSelectedSubscription(String subscriptionId) async {
    await initialize();
    try {
      await _prefs.setString(_selectedSubscriptionKey, subscriptionId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Очистить выбранную подписку
  Future<bool> clearSelectedSubscription() async {
    await initialize();
    try {
      await _prefs.remove(_selectedSubscriptionKey);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Получить выбранную подписку со всеми данными
  Future<VpnSubscription?> getSelectedSubscription() async {
    final id = await getSelectedSubscriptionId();
    if (id == null) return null;
    return getSubscription(id);
  }

  /// Вспомогательный метод для сохранения всех подписок
  Future<bool> clearAllSubscriptions() async {
    await initialize();
    try {
      await _prefs.remove(_storageKey);
      await _prefs.remove(_selectedSubscriptionKey);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveAll(List<VpnSubscription> subscriptions) async {
    final jsonList = subscriptions
        .map((sub) => jsonEncode(sub.toJson()))
        .toList();
    await _prefs.setStringList(_storageKey, jsonList);
  }
}
