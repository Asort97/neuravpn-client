import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../vless/vless_parser.dart';

class SubscriptionFetchException implements Exception {
  const SubscriptionFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SubscriptionService {
  final http.Client _client = http.Client();
  final Duration _timeout;
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';

  SubscriptionService({Duration? timeout})
    : _timeout = timeout ?? const Duration(seconds: 30);

  /// Загрузить подписку с URL
  /// Возвращает список VLESS URI из подписки
  Future<List<String>> fetchSubscription(String url) async {
    try {
      // Добавляем проверку на валидный URL
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
        throw const SubscriptionFetchException('Неверный формат URL');
      }

      final body = await _fetchBody(uri);
      final content = _decodeSubscriptionContent(body);

      if (content == null) {
        throw const SubscriptionFetchException(
          'Подписка должна быть в base64 или содержать VLESS ссылки',
        );
      }

      final profiles = _parseProfiles(content);
      if (profiles.isEmpty) {
        throw const SubscriptionFetchException(
          'Подписка не содержит поддерживаемых TLS/Reality профилей',
        );
      }

      return profiles;
    } on SubscriptionFetchException {
      rethrow;
    } on HandshakeException {
      throw const SubscriptionFetchException(
        'Не удалось установить защищённое соединение с сервером подписки. '
        'Попробуйте ещё раз или откройте ссылку через другую сеть.',
      );
    } on SocketException catch (e) {
      throw SubscriptionFetchException('Ошибка сети: ${e.message}');
    } on TimeoutException {
      throw const SubscriptionFetchException(
        'Сервер подписки не ответил вовремя',
      );
    } catch (e) {
      throw SubscriptionFetchException(e.toString());
    }
  }

  Future<String> _fetchBody(Uri uri) async {
    try {
      final response = await _client
          .get(uri, headers: {'User-Agent': _userAgent, 'Accept': '*/*'})
          .timeout(_timeout);

      if (response.statusCode != 200) {
        throw SubscriptionFetchException('Ошибка HTTP ${response.statusCode}');
      }
      return response.body;
    } on HandshakeException {
      final fallback = await _fetchBodyWithCurl(uri);
      if (fallback != null) return fallback;
      rethrow;
    } on SocketException {
      final fallback = await _fetchBodyWithCurl(uri);
      if (fallback != null) return fallback;
      rethrow;
    }
  }

  Future<String?> _fetchBodyWithCurl(Uri uri) async {
    if (!Platform.isWindows) return null;
    try {
      final result = await Process.run('curl.exe', <String>[
        '--location',
        '--silent',
        '--show-error',
        '--max-time',
        '${_timeout.inSeconds}',
        '--user-agent',
        _userAgent,
        uri.toString(),
      ]).timeout(_timeout + const Duration(seconds: 2));
      if (result.exitCode == 0) {
        final body = result.stdout?.toString() ?? '';
        if (body.trim().isNotEmpty) return body;
      }
    } catch (_) {}
    return null;
  }

  String? _decodeSubscriptionContent(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains('vless://')) {
      return trimmed;
    }

    final compact = trimmed.replaceAll(RegExp(r'\s+'), '');
    try {
      final normalized = base64.normalize(compact);
      return utf8.decode(base64.decode(normalized), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// Парсить VLESS URI из текста.
  List<String> _parseProfiles(String content) {
    final profiles = <String>[];

    final matches = RegExp(r'vless://[^\s]+').allMatches(content);
    for (final match in matches) {
      final uri = match.group(0)?.trim();
      if (uri == null || uri.isEmpty) continue;
      if (isSecureVlessUri(uri)) {
        profiles.add(uri);
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
