import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../vless/proxy_parser.dart';
import 'subscription_request_identity.dart';

class SubscriptionFetchException implements Exception {
  const SubscriptionFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SubscriptionDeviceLimitException extends SubscriptionFetchException {
  const SubscriptionDeviceLimitException(super.message);
}

class SubscriptionService {
  final http.Client _client;
  final Duration _timeout;
  final SubscriptionRequestIdentity _identity;
  final bool _isWindows;
  final Future<ProcessResult> Function(String, List<String>) _runProcess;

  SubscriptionService({
    Duration? timeout,
    http.Client? client,
    SubscriptionRequestIdentity? identity,
    bool? isWindowsOverride,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
  }) : _timeout = timeout ?? const Duration(seconds: 30),
       _client = client ?? http.Client(),
       _identity = identity ?? SubscriptionRequestIdentity.instance,
       _isWindows = isWindowsOverride ?? Platform.isWindows,
       _runProcess = runProcess ?? _runCurl;

  /// Загрузить подписку с URL
  /// Возвращает список VLESS/Hysteria 2 URI из подписки
  Future<List<String>> fetchSubscription(String url) async {
    try {
      // Добавляем проверку на валидный URL
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !uri.isAbsolute ||
          uri.host.isEmpty ||
          (uri.scheme != 'https' && uri.scheme != 'http')) {
        throw const SubscriptionFetchException('Неверный формат URL');
      }

      Map<String, String> headers;
      try {
        headers = await _identity.headers();
      } catch (_) {
        throw const SubscriptionFetchException(
          'Не удалось прочитать или сохранить ID установки. '
          'Проверьте доступ к данным приложения и попробуйте снова.',
        );
      }
      final response = await _fetchResponse(uri, headers);
      // A limit response may deliberately contain a syntactically valid dummy URI.
      // Check the headers before HTTP status, decoding or updating saved profiles.
      if (_header(response, 'x-neura-device-limit')?.trim().toLowerCase() ==
          'true') {
        throw SubscriptionDeviceLimitException(
          _deviceLimitMessage(_header(response, 'profile-title')),
        );
      }
      if (response.statusCode != 200) {
        throw SubscriptionFetchException('Ошибка HTTP ${response.statusCode}');
      }
      final content = _decodeSubscriptionContent(response.body);

      if (content == null) {
        throw const SubscriptionFetchException(
          'Подписка должна быть в base64 или содержать VLESS или Hysteria 2 ссылки',
        );
      }

      final profiles = _parseProfiles(content);
      if (profiles.isEmpty) {
        throw const SubscriptionFetchException(
          'Подписка не содержит поддерживаемых VLESS/Hysteria 2 профилей',
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
    } on http.ClientException catch (e) {
      throw SubscriptionFetchException(
        'Ошибка загрузки подписки: ${e.message}',
      );
    } on TimeoutException {
      throw const SubscriptionFetchException(
        'Сервер подписки не ответил вовремя',
      );
    } catch (e) {
      throw SubscriptionFetchException(e.toString());
    }
  }

  Future<http.Response> _fetchResponse(
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      return await _getWithRedirects(uri, headers).timeout(_timeout);
    } on HandshakeException {
      final fallback = await _fetchWithCurl(uri, headers);
      if (fallback != null) return fallback;
      rethrow;
    } on SocketException {
      final fallback = await _fetchWithCurl(uri, headers);
      if (fallback != null) return fallback;
      rethrow;
    } on http.ClientException {
      final fallback = await _fetchWithCurl(uri, headers);
      if (fallback != null) return fallback;
      rethrow;
    }
  }

  Future<http.Response> _getWithRedirects(
    Uri uri,
    Map<String, String> headers,
  ) async {
    var current = uri;
    for (var redirects = 0; ; redirects++) {
      // dart:io may replace User-Agent when following redirects automatically.
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(headers);
      final response = await _client.send(request);
      final location = response.headers['location'];
      if (location == null ||
          !const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        return http.Response.fromStream(response);
      }
      await response.stream.drain<void>();
      final next = current.resolve(location);
      if (redirects >= 5 ||
          next.host.isEmpty ||
          (next.scheme != 'https' && next.scheme != 'http')) {
        throw const SubscriptionFetchException(
          'Сервер подписки вернул недопустимое перенаправление',
        );
      }
      current = next;
    }
  }

  static Future<ProcessResult> _runCurl(String executable, List<String> args) =>
      Process.run(executable, args, stdoutEncoding: null, stderrEncoding: utf8);

  Future<http.Response?> _fetchWithCurl(
    Uri uri,
    Map<String, String> headers,
  ) async {
    if (!_isWindows) return null;
    Directory? temp;
    try {
      temp = await Directory.systemTemp.createTemp('neuravpn_subscription_');
      final headerFile = File('${temp.path}/headers');
      final result = await _runProcess('curl.exe', <String>[
        '--disable',
        '--location',
        '--max-redirs',
        '5',
        '--proto',
        '=http,https',
        '--proto-redir',
        '=http,https',
        '--silent',
        '--show-error',
        '--connect-timeout',
        '10',
        '--max-time',
        '${_timeout.inSeconds}',
        '--dump-header',
        headerFile.path,
        for (final entry in headers.entries) ...[
          '--header',
          '${entry.key}: ${entry.value}',
        ],
        uri.toString(),
      ]).timeout(_timeout + const Duration(seconds: 2));
      if (result.exitCode == 0) {
        final rawHeaders = await headerFile.readAsString(encoding: latin1);
        return _curlResponse(rawHeaders, result.stdout as List<int>);
      }
    } catch (_) {
      // The original transport error is more useful to the caller.
    } finally {
      if (temp != null) {
        try {
          await temp.delete(recursive: true);
        } catch (_) {}
      }
    }
    return null;
  }

  http.Response? _curlResponse(String rawHeaders, List<int> body) {
    int? status;
    final headers = <String, String>{};
    // curl emits headers for CONNECT, redirects and the final response.
    for (final block in rawHeaders.split(RegExp(r'\r?\n\r?\n'))) {
      final lines = const LineSplitter().convert(block);
      if (lines.isEmpty) continue;
      final match = RegExp(
        r'^HTTP/\S+\s+(\d{3})(?:\s|$)',
      ).firstMatch(lines.first);
      if (match == null) continue;
      status = int.parse(match.group(1)!);
      headers.clear();
      for (final line in lines.skip(1)) {
        final separator = line.indexOf(':');
        if (separator <= 0) continue;
        headers[line.substring(0, separator).trim().toLowerCase()] = line
            .substring(separator + 1)
            .trim();
      }
    }
    return status == null
        ? null
        : http.Response.bytes(body, status, headers: headers);
  }

  String? _header(http.Response response, String name) {
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  String _deviceLimitMessage(String? title) {
    const fallback =
        'Достигнут лимит устройств для этой подписки. '
        'Удалите ненужное устройство в личном кабинете или обратитесь в поддержку.';
    var text = title?.trim() ?? '';
    if (text.toLowerCase().startsWith('base64:')) {
      try {
        text = utf8.decode(
          base64.decode(base64.normalize(text.substring(7).trim())),
        );
      } on FormatException {
        return fallback;
      }
    }
    text = text
        .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '')
        .trim();
    return text.isEmpty ? fallback : text;
  }

  String? _decodeSubscriptionContent(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (RegExp(
      r'(?:vless|hysteria2|hy2)://',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return trimmed;
    }

    final compact = trimmed.replaceAll(RegExp(r'\s+'), '');
    try {
      final normalized = base64.normalize(compact);
      return utf8.decode(base64.decode(normalized), allowMalformed: true);
    } catch (_) {
      try {
        final normalized = base64Url.normalize(compact);
        return utf8.decode(base64Url.decode(normalized), allowMalformed: true);
      } catch (_) {
        return null;
      }
    }
  }

  /// Парсить VLESS/Hysteria 2 URI из текста.
  List<String> _parseProfiles(String content) {
    final profiles = <String>[];
    final seen = <String>{};

    final matches = RegExp(
      r'(?:vless|hysteria2|hy2)://[^\s]+',
      caseSensitive: false,
    ).allMatches(content);
    for (final match in matches) {
      final uri = match.group(0)?.trim().replaceFirst(RegExp("[\"',;]+\$"), '');
      if (uri == null || uri.isEmpty) continue;
      if (isSecureProxyUri(uri) && seen.add(uri)) {
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
      return uri.host.isNotEmpty &&
          (uri.scheme == 'https' || uri.scheme == 'http');
    } catch (_) {
      return false;
    }
  }
}
