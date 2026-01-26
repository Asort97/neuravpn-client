import 'dart:collection';

/// Мини-библиотека расширения доменов по семействам сервисов.
class DomainFamilies {
  /// Вернёт множество доменов/суффиксов, которые нужно добавить в правила
  /// для указанного входа (URL/host/eTLD+1).
  static Set<String> expand(String input) {
    final host = _extractHost(input);
    if (host.isEmpty) return {};

    final result = <String>{};
    final base = _stripWww(host);
    final etld = _etldPlusOne(base);

    if (host.isNotEmpty) result.add(host);
    if (base.isNotEmpty) result.add(base);
    if (etld.isNotEmpty) result.add(etld);

    for (final entry in _families.entries) {
      if (base == entry.key || base.endsWith('.${entry.key}')) {
        result.addAll(entry.value);
        break;
      }
    }

    return LinkedHashSet.of(
      result.map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty),
    );
  }

  /// Извлекает хост из URL/строки.
  static String _extractHost(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    value = value.toLowerCase();

    // Если пользователь вводит bare host без схемы, добавим схему для парсинга.
    if (!value.contains('://')) {
      value = 'http://$value';
    }
    try {
      final uri = Uri.parse(value);
      var host = uri.host.trim().toLowerCase();
      if (host.contains(':')) {
        host = host.split(':').first;
      }
      return host;
    } catch (_) {
      // Fallback: удалить путь/протокол вручную.
      final cleaned = raw
          .replaceFirst(RegExp(r'^[a-z]+:\/\/', caseSensitive: false), '')
          .split('/')
          .first;
      return cleaned.split(':').first.toLowerCase();
    }
  }

  static String _stripWww(String host) {
    if (host.startsWith('www.')) {
      return host.substring(4);
    }
    return host;
  }

  /// Простейший etld+1: последние две части домена.
  static String _etldPlusOne(String host) {
    final parts = host.split('.').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) return host;
    return '${parts[parts.length - 2]}.${parts.last}';
  }

  static final Map<String, Set<String>> _families = {
    'youtube.com': {
      'youtube.com',
      'youtu.be',
      'youtubei.googleapis.com',
      'youtubeembeddedplayer.googleapis.com',
      'youtube-nocookie.com',
      'youtubekids.com',
      'ytimg.com',
      'ytimg.l.google.com',
      'yt3.ggpht.com',
      'yt4.ggpht.com',
      'yt3.googleusercontent.com',
      'googlevideo.com',
      'jnn-pa.googleapis.com',
      'wide-youtube.l.google.com',
      'yt-video-upload.l.google.com',
    },
    'discord.com': {
      'discord.com',
      'discord.gg',
      'discordapp.com',
      'discordapp.net',
      'discord.media',
      'discordcdn.com',
      'discord.gifts',
      'discord.gift',
      'discord-activities.com',
      'discordactivities.com',
      'discord.new',
      'discord.status',
      'discordstatus.com',
      'discord.design',
      'discord.dev',
      'discord.store',
      'discord.co',
      'discord.app',
      'discord-attachments-uploads-prd.storage.googleapis.com',
      'discordpartygames.com',
      'discordsays.com',
      'discordsez.com',
      'dis.gd',
      'betterttv.net',
      'ffzap.com',
      'frankerfacez.com',
      '7tv.app',
      '7tv.io',
      'localizeapi.com',
      'cloudflare-ech.com',
      'encryptedsni.com',
      'cloudflareaccess.com',
      'cloudflareapps.com',
      'cloudflarebolt.com',
      'cloudflareclient.com',
      'cloudflareinsights.com',
      'cloudflareok.com',
      'cloudflarepartners.com',
      'cloudflareportal.com',
      'cloudflarepreview.com',
      'cloudflareresolve.com',
      'cloudflaressl.com',
      'cloudflarestatus.com',
      'cloudflarestorage.com',
      'cloudflarestream.com',
      'cloudflaretest.com',
    },
  };
}
