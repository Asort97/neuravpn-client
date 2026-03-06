import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../vless/vless_parser.dart';

class SubscriptionService {
  final http.Client _client = http.Client();
  final Duration _timeout;

  SubscriptionService({Duration? timeout}) 
    : _timeout = timeout ?? const Duration(seconds: 30);

  /// Загрузить подписку с URL
  /// Возвращает список VLESS URI из подписки
  Future<List<String>> fetchSubscription(String url) async {
    try {
      // Добавляем проверку на валидный URL
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasAbsolutePath) {
        throw 'Неверный формат URL';
      }

      final response = await _client.get(
        uri,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      ).timeout(_timeout);

      if (response.statusCode != 200) {
        throw 'Ошибка HTTP ${response.statusCode}';
      }

      // Пробуем декодировать base64
      final decodedContent = _decodeBase64(response.body);
      if (decodedContent == null) {
        throw 'Не удалось декодировать base64';
      }

      // Парсим строки с профилями
      final profiles = _parseProfiles(decodedContent);
      if (profiles.isEmpty) {
        throw 'Подписка не содержит поддерживаемых TLS/Reality профилей';
      }

      return profiles;
    } on SocketException catch (e) {
      throw 'Ошибка сети: $e';
    } catch (e) {
      throw 'Ошибка: $e';
    }
  }

  /// Декодировать base64
  String? _decodeBase64(String encoded) {
    try {
      final decoded = utf8.decode(base64.decode(encoded));
      return decoded;
    } catch (_) {
      return null;
    }
  }

  /// Парсить VLESS URI из текста
  /// Поддерживает разделение по строкам
  List<String> _parseProfiles(String content) {
    final profiles = <String>[];

    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Проверяем что это VLESS URI
      if (trimmed.startsWith('vless://')) {
        if (isSecureVlessUri(trimmed)) {
          profiles.add(trimmed);
        }
      }
    }

    return profiles;
  }

  /// Получить информацию о подписке (количество профилей, дату)
  Future<Map<String, dynamic>> getSubscriptionInfo(String url) async {
    final profiles = await fetchSubscription(url);

    return {
      'count': profiles.length,
      'timestamp': DateTime.now(),
      'profiles': profiles,
    };
  }

  /// Валидировать URL подписки
  bool isValidSubscriptionUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.isAbsolute && uri.hasScheme;
    } catch (_) {
      return false;
    }
  }
}

