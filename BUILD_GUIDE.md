# Инструкция по сборке и запуску

## Быстрый старт

### 1. Подготовка окружения

```powershell
# Проверка Flutter
flutter doctor

# Клонирование (если ещё не сделано)
git clone <repo_url>
cd happycat_vpnclient
```

### 2. Скачивание необходимых файлов

#### sing-box.exe
```powershell
# Скачайте последний релиз
# https://github.com/SagerNet/sing-box/releases
# Пример для версии 1.8.0
Invoke-WebRequest -Uri "https://github.com/SagerNet/sing-box/releases/download/v1.8.0/sing-box-1.8.0-windows-amd64.zip" -OutFile "sing-box.zip"
Expand-Archive sing-box.zip -DestinationPath .
Move-Item sing-box-*/sing-box.exe .
Remove-Item sing-box.zip, sing-box-* -Recurse
```

#### wintun.dll
```powershell
# Скачайте wintun
Invoke-WebRequest -Uri "https://www.wintun.net/builds/wintun-0.14.1.zip" -OutFile "wintun.zip"
Expand-Archive wintun.zip -DestinationPath .
Copy-Item wintun/bin/amd64/wintun.dll assets/bin/
Remove-Item wintun.zip, wintun -Recurse
```

### 3. Установка зависимостей

```powershell
flutter pub get
```

### 4. Запуск в режиме разработки

```powershell
# Запуск приложения
flutter run -d windows

# Или сборка release
flutter build windows --release
```

### 5. Использование

1. Откройте приложение
2. Вставьте VLESS URI в поле (например из примера в CONFIG_EXAMPLES.md)
3. Нажмите **Start**
4. Дождитесь статуса "Подключено (TUN: wintun0)"
5. Проверьте подключение: `curl https://ifconfig.me`

## Структура проекта после подготовки

```
happycat_vpnclient/
├── sing-box.exe              # Ядро VPN
├── assets/
│   └── bin/
│       └── wintun.dll        # Windows TUN драйвер
├── lib/
│   ├── main.dart             # UI приложения
│   ├── models/
│   │   └── split_tunnel_config.dart
│   ├── services/
│   │   └── wintun_manager.dart
│   └── vless/
│       ├── config_generator.dart
│       └── vless_parser.dart
├── pubspec.yaml
└── README.md
```

## Сборка release версии

```powershell
# Полная сборка
flutter build windows --release

# Результат в:
# build/windows/x64/runner/Release/

# Необходимо скопировать рядом с .exe:
Copy-Item sing-box.exe build/windows/x64/runner/Release/
Copy-Item assets/bin/wintun.dll build/windows/x64/runner/Release/data/flutter_assets/assets/bin/
```

## Упаковка для распространения

```powershell
# Создать архив для пользователей
$version = "1.0.0"
$releasePath = "build/windows/x64/runner/Release"
$packageName = "happycat_vpnclient_v${version}_windows_x64"

# Копирование всех файлов
New-Item -ItemType Directory -Path $packageName -Force
Copy-Item -Path "$releasePath/*" -Destination $packageName -Recurse
Copy-Item sing-box.exe $packageName/
Copy-Item README.md $packageName/

# Создание архива
Compress-Archive -Path $packageName -DestinationPath "${packageName}.zip"
```
ывап
## Требования к системе

### Минимальные
- Windows 10 x64 (1809+)
- 100 MB свободного места
- Права администратора (для создания TUN интерфейса)

### Рекомендуемые
- Windows 11 x64
- 256 MB RAM
- Постоянное интернет-соединение

## Известные ограничения

1. **Только Windows 10/11 x64** - 32-bit не поддерживается
2. **Нужны права администратора** для создания TUN интерфейса
3. **Один активный туннель** - нельзя запустить несколько экземпляров
4. **Split tunneling по процессам** требует дополнительных инструментов (Proxifier)

## Устранение неполадок

### Приложение не запускается
```powershell
# Проверка Flutter
flutter doctor -v

# Очистка кеша
flutter clean
flutter pub get
```

### sing-box не найден
```powershell
# Проверка наличия файла
Test-Path sing-box.exe

# Если нет - скачайте заново
```

### wintun.dll не найден
```powershell
# Проверка в assets
Test-Path assets/bin/wintun.dll

# После сборки проверьте:
Test-Path build/windows/x64/runner/Release/data/flutter_assets/assets/bin/wintun.dll
```

### TUN интерфейс не создаётся
- Запустите от администратора (правой кнопкой → "Запуск от имени администратора")
- Проверьте антивирус (может блокировать создание виртуальных адаптеров)
- Убедитесь что wintun.dll корректный (не заглушка)

## Обновление

### Обновление sing-box
```powershell
# Скачайте новую версию
# Замените sing-box.exe
# Перезапустите приложение
```

### Обновление приложения
```powershell
git pull
flutter pub get
flutter build windows --release
```

## Логи и отладка

### Логи sing-box
Логи выводятся в UI приложения в реальном времени.
Можно копировать выделением текста.

### Экспорт конфигурации
Нажмите кнопку **Show Config** для просмотра сгенерированного config.json

### Ручной запуск sing-box для отладки
```powershell
# Найдите путь к config в UI (например):
# Config: C:\Users\...\AppData\Local\Temp\singbox_cfg_xxx\config.json

# Запустите вручную
.\sing-box.exe run -c "C:\путь\к\config.json"
```

## Поддержка

- Issues: https://github.com/your-repo/issues
- Документация: README.md, CONFIG_EXAMPLES.md
- sing-box docs: https://sing-box.sagernet.org/
