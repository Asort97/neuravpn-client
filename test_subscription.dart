import 'dart:convert';
import 'lib/vless/vless_parser.dart';
import 'lib/vless/config_generator.dart';
import 'lib/models/split_tunnel_config.dart';

void main() {
  // Synthetic test URI only (no real infrastructure or credentials).
  const testUri = 'vless://11111111-1111-1111-1111-111111111111@example.com:443?encryption=none&flow=xtls-rprx-vision&fp=chrome&pbk=TEST_PUBLIC_KEY_ONLY&security=reality&sid=deadbeef&sni=example.com&spx=%2F&type=tcp#example-test-profile';
  
  print('Парсинг VLESS URI...');
  final parsed = parseVlessUri(testUri);
  
  if (parsed == null) {
    print('❌ Ошибка парсинга URI');
    return;
  }
  
  print('✅ URI распарсен успешно:');
  print('  UUID: ${parsed.uuid}');
  print('  Host: ${parsed.host}');
  print('  Port: ${parsed.port}');
  print('  Security: ${parsed.security}');
  print('  Flow: ${parsed.flow}');
  print('  SNI: ${parsed.sni}');
  print('  Public Key: ${parsed.params['pbk']}');
  print('  Short ID: ${parsed.params['sid']}');
  print('  Spider X: ${parsed.params['spx']}');
  print('');
  
  print('Генерация конфига...');
  final config = SplitTunnelConfig();
  final jsonConfig = generateSingBoxConfig(parsed, config);
  
  print('');
  print('=' * 80);
  print('Сгенерированный конфиг:');
  print('=' * 80);
  
  // Красивый вывод JSON
  final decoded = jsonDecode(jsonConfig);
  final prettyJson = const JsonEncoder.withIndent('  ').convert(decoded);
  print(prettyJson);
  
  // Проверяем наличие spider_x в Reality секции
  print('');
  print('=' * 80);
  print('Проверка Reality параметров:');
  print('=' * 80);
  
  final outbounds = decoded['outbounds'] as List;
  final vlessOutbound = outbounds.firstWhere((o) => o['type'] == 'vless');
  final tls = vlessOutbound['tls'];
  
  if (tls != null) {
    final reality = tls['reality'];
    if (reality != null) {
      print('✅ Reality секция найдена:');
      print('  Enabled: ${reality['enabled']}');
      print('  Public Key: ${reality['public_key']}');
      print('  Short ID: ${reality['short_id']}');
      print('  Spider X: ${reality['spider_x']}');
      
      if (reality['spider_x'] != null) {
        print('');
        print('✅ Параметр spider_x успешно добавлен в конфиг!');
      } else {
        print('');
        print('❌ ОШИБКА: Параметр spider_x отсутствует в конфиге!');
      }
    } else {
      print('❌ Reality секция не найдена');
    }
  } else {
    print('❌ TLS секция не найдена');
  }
}
