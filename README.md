# happycat_vpnclient


## Smart Routing Zapret (cross-platform)
- Adds a third path: `direct-evasion` (direct + evasion proxy) without IP change.
- Live telemetry: local DNS proxy + direct-evasion SOCKS proxy for real traffic signals.
- Auto-probe: local SOCKS probes through VPN/direct/direct-evasion, rate-limited.
- Bootstrap suspects: uses zapret domain lists only as candidates for probing.
- Learned decisions cached per network profile for 12h; resettable in advanced.
- Legacy WinDivert-based mode is disabled by default.

Limitations: relies on SNI/HTTP host classification and lightweight TLS fragmentation (no TTL tricks).

VLESS VPN клиент на Flutter для Windows с полноценным TUN туннелем (wintun). UI принимает VLESS URI, генерирует конфиг для **sing-box** с TUN inbound, создаёт системный VPN туннель для всего устройства.

## Быстрый старт (Windows)

### Требования
- Windows 10/11 (x64)
- sing-box.exe
- wintun.dll (опционально, можно в assets)
- WinDivert.dll + WinDivert64.sys (для split tunneling приложений)

### Установка

1. **Скачайте sing-box**  
   Загрузите релиз с GitHub: https://github.com/SagerNet/sing-box/releases  
   Извлеките `sing-box.exe` (windows-amd64) и поместите:
   - `./sing-box.exe` (корень проекта)
   - или `./windows/sing-box.exe`
   - или `./assets/bin/sing-box.exe`

2. **Скачайте wintun.dll**  
   - Загрузите архив с https://www.wintun.net/builds/wintun-0.14.1.zip
   - Извлеките `wintun/bin/amd64/wintun.dll`
   - Поместите в `assets/bin/wintun.dll` перед компиляцией
   - Или положите рядом с `sing-box.exe` после сборки

3. **Установите зависимости и запустите**
```powershell
flutter pub get
flutter run -d windows
```

4. **(Опционально) Добавьте WinDivert для split tunneling приложений**  
   - Скачайте драйвер с https://reqrypt.org/windivert.html (релиз `WinDivert-2.x-A.zip`)
   - Поместите `WinDivert.dll` и `WinDivert64.sys` в `assets/bin/`
   - Приложение автоматически извлечёт и подключит драйвер при запуске (нужны права администратора)

5. **Введите VLESS URI**  
   Формат (Reality example):
```
vless://UUID@host:443?type=tcp&security=reality&sni=example.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&flow=xtls-rprx-vision#tag
```

6. **Подключитесь**  
   Нажмите `Start`. Статус изменится на «Подключено (TUN: wintun0)».  
   Весь трафик системы теперь идёт через VPN туннель.

## Формат VLESS URI
Базовый вид: `vless://UUID@HOST:PORT?param1=...&param2=...#TAG`
Ключевые параметры:
- `type=ws` (транспорт WebSocket) или другой тип
- `security=tls` (TLS) / `security=reality`
- `path=/xxx` (для ws)
- `host=example.com` (для заголовка Host при ws)
- `sni=example.com` (TLS SNI)
Дополнительно: `alpn=h2,http/1.1`, `flow=xtls-rprx-vision`, `fp=chrome` и т.д.

## Как работает

1. **Парсинг URI**: `lib/vless/vless_parser.dart` с валидацией UUID, host, port, параметров Reality
2. **Генерация конфигурации**: `lib/vless/config_generator.dart` создаёт JSON для sing-box с:
   - TUN inbound (wintun stack)
   - DNS servers (local + remote TLS)
   - VLESS Reality outbound с корректными параметрами
   - Split tunneling rules
3. **Управление wintun**: `lib/services/wintun_manager.dart` извлекает DLL из assets
4. **Запуск процесса**: `sing-box.exe run -c <config.json>`, логи в UI
5. **Системный VPN**: Создаётся виртуальный сетевой адаптер wintun0, весь трафик идёт через туннель

## Частые проблемы

| Проблема | Причина | Решение |
|----------|---------|---------|
| «Не найден sing-box.exe» | Бинарник не в ожидаемом месте | Поместите `sing-box.exe` в корень проекта |
| «wintun.dll не найден» | DLL отсутствует | Скачайте с wintun.net и поместите в `assets/bin/` |
| Процесс завершился (код 1) | Ошибка в конфиге или параметры Reality неверны | Проверьте UUID, public_key, short_id, SNI |
| «Access denied» или TUN ошибка | Недостаточно прав | Запустите приложение от администратора |
| Соединение обрывается | Неверные параметры сервера | Проверьте flow=xtls-rprx-vision, packet_encoding=xudp |
| DNS не работает | Проблема с DNS routing | Убедитесь что sing-box >= 1.8.0 |

## Технические детали

### TUN режим
- **Stack**: `system` (Windows native)
- **Interface**: `wintun0`
- **MTU**: 1400
- **Address**: 172.19.0.1/30
- **Auto-route**: Да (весь трафик через туннель)

### VLESS Reality параметры
- **Flow**: `xtls-rprx-vision` (обязательно для Reality)
- **Packet encoding**: `xudp` (автоматически для vision flow)
- **TLS**: uTLS с fingerprint `chrome`
- **Reality**: public_key, short_id (строка, не массив при одном значении)

### Split Tunneling
- **Режим "all"**: Весь трафик через VPN
- **Режим "whitelist"**: Только указанные домены/IP через VPN
- **Режим "blacklist"**: Указанные домены/IP напрямую
- Поддержка доменов и IP CIDR
- Приложения (.exe) требуют WinDivert: укажите путь в разделе «Приложения», чтобы направлять конкретные процессы в VPN/в обход

## TODO
- [x] TUN inbound с wintun
- [x] VLESS Reality корректная генерация
- [x] DNS sing-box 1.12+ формат
- [x] Split tunneling routing rules
- [ ] GUI выбор пути к sing-box.exe
- [ ] Множественные профили
- [ ] Автоматическое обновление sing-box
- [ ] Статистика трафика
- [ ] Системный трей
- [ ] Автозапуск с Windows

## Расширение
Чтобы указать путь явно, можно будет добавить поле настроек (ещё не реализовано). Временное решение: отредактируйте функцию `_resolveBinaryPath()` в `main.dart`.

## Ресурсы по Flutter
- https://docs.flutter.dev
- https://pub.dev (пакеты)
- https://codelabs.developers.google.com/?cat=Flutter

## Лицензия
Пока не указана — добавьте при необходимости.
