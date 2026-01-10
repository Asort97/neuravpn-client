import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/split_tunnel_config.dart';
import 'android_vpn_controller.dart';
import 'singbox_binary_manager.dart';
import 'windows_tun_guard.dart';
import 'windivert_manager.dart';
import 'wintun_manager.dart';
import '../services/smart_route_engine.dart';
import '../vless/config_generator.dart';
import '../vless/vless_parser.dart';
import 'dpi_evasion_config.dart';

class SingBoxStartResult {
  final bool success;
  final String? errorMessage;
  final bool requiresAdmin;

  const SingBoxStartResult._({
    required this.success,
    this.errorMessage,
    this.requiresAdmin = false,
  });

  factory SingBoxStartResult.success() =>
      const SingBoxStartResult._(success: true);

  factory SingBoxStartResult.failure(
    String message, {
    bool requiresAdmin = false,
  }) => SingBoxStartResult._(
    success: false,
    errorMessage: message,
    requiresAdmin: requiresAdmin,
  );
}

class SingBoxController {
  SingBoxController({
    WintunManager? wintunManager,
    WindowsTunGuard? tunGuard,
    SingBoxBinaryManager? binaryManager,
    AndroidVpnController? androidController,
    WinDivertManager? winDivertManager,
  }) : _wintunManager = wintunManager ?? WintunManager(),
       _tunGuard = tunGuard ?? WindowsTunGuard(),
       _binaryManager = binaryManager ?? SingBoxBinaryManager(),
       _androidController = androidController ?? AndroidVpnController(),
       _winDivertManager = winDivertManager ?? WinDivertManager();

  final WintunManager _wintunManager;
  final WindowsTunGuard _tunGuard;
  final SingBoxBinaryManager _binaryManager;
  final AndroidVpnController _androidController;
  final WinDivertManager _winDivertManager;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _androidConnected = false;
  bool _accessDeniedDetected = false;
  bool _startupCheckInProgress = false;
  WebSocket? _trafficSocket;
  StreamSubscription? _trafficSocketSub;
  final StreamController<int> _trafficController =
      StreamController<int>.broadcast();

  String? _activeInterfaceName;
  File? _configFile;
  String? _generatedConfig;
  VlessLink? _parsedLink;
  String? _lastStartError;
  final List<String> _recentLogs = <String>[];
  static const int _clashApiPort = 9090;

  void Function(String status)? _statusSink;
  void Function(String log)? _logSink;

  VlessLink? get parsedLink => _parsedLink;
  File? get configFile => _configFile;
  String? get generatedConfig => _generatedConfig;
  int get clashApiPort => _clashApiPort;
  Stream<int> get trafficStream => _trafficController.stream;

  String get interfaceLabel {
    if (Platform.isWindows) {
      return _activeInterfaceName ?? WindowsTunGuard.defaultInterfaceName;
    }
    return 'Android VPN';
  }

  bool get isRunning =>
      Platform.isAndroid ? _androidConnected : _process != null;

  Future<bool> isWintunAvailable() => _wintunManager.isWintunAvailable();

  Future<SingBoxStartResult> connect({
    required String rawUri,
    required SplitTunnelConfig splitConfig,
    SmartRouteEngine? smartRouteEngine,
    DpiEvasionConfig dpiEvasionConfig = DpiEvasionConfig.balanced,
    void Function(String status)? onStatus,
    void Function(String log)? onLog,
  }) async {
    _statusSink = onStatus;
    _logSink = onLog;
    _accessDeniedDetected = false;
    _lastStartError = null;
    _recentLogs.clear();

    final trimmed = rawUri.trim();
    if (trimmed.isEmpty) {
      return SingBoxStartResult.failure('Ошибка: пустой VLESS URI');
    }

    final parsed = parseVlessUri(trimmed);
    if (parsed == null) {
      return SingBoxStartResult.failure('Ошибка: неверный формат VLESS URI');
    }
    _parsedLink = parsed;

    if (!Platform.isWindows && !Platform.isAndroid) {
      return SingBoxStartResult.failure('Платформа не поддерживается');
    }

    String inboundTag = WindowsTunGuard.defaultInboundTag;
    String interfaceName = WindowsTunGuard.defaultInterfaceName;
    List<String> interfaceAddresses = const ['172.19.0.1/30'];
    WinDivertPaths? winDivertPaths;

    if (Platform.isWindows) {
      if (_activeInterfaceName != null) {
        final logs = await _tunGuard.cleanupAdapter(_activeInterfaceName);
        _emitLogs(logs);
        _activeInterfaceName = null;
      }
      _notifyStatus('Проверка TUN интерфейса');
      final guardResult = await _tunGuard.prepare();
      _emitLogs(guardResult.logs);

      if (!guardResult.success) {
        final message = guardResult.requiresElevation
            ? '❌ Нужны права администратора для управления TUN интерфейсом'
            : (guardResult.error ?? 'Не удалось подготовить TUN интерфейс');
        return SingBoxStartResult.failure(
          message,
          requiresAdmin: guardResult.requiresElevation,
        );
      }

      inboundTag = guardResult.inboundTag;
      interfaceName = guardResult.interfaceName;
      interfaceAddresses = guardResult.addresses;
      _activeInterfaceName = interfaceName;

      if (guardResult.leftoverAdapters.isNotEmpty) {
        unawaited(
          _tunGuard
              .cleanupAdapters(guardResult.leftoverAdapters)
              .then(_emitLogs),
        );
      }

      _notifyStatus('Подготовка WinDivert');
      winDivertPaths = await _winDivertManager.ensureAvailable();
      if (winDivertPaths == null || !winDivertPaths.isReady) {
        return SingBoxStartResult.failure(
          'WinDivert не найден. Убедитесь, что WinDivert.dll и WinDivert64.sys добавлены в assets/bin.',
        );
      }
    } else {
      _activeInterfaceName = null;
    }

    final androidPackages = Platform.isAndroid
        ? _extractAndroidPackages(splitConfig)
        : <String>[];

    _notifyStatus('Генерация конфига');
    final extraRouteRules = <Map<String, dynamic>>[];
    final useSmartEngineRules =
        smartRouteEngine != null && splitConfig.smartRouting;
    if (useSmartEngineRules) {
      extraRouteRules.addAll(
        smartRouteEngine.buildRouteRules(outboundTag: 'direct'),
      );
    }
    if (dpiEvasionConfig.enableTlsFragment) {
      extraRouteRules.add(
        SmartRouteEngine.buildTlsFragmentRouteOptionsRule(
          options: SmartTlsFragmentOptions(
            fallbackDelay: dpiEvasionConfig.tlsFragmentFallbackDelay,
          ),
        ),
      );
    }

    final jsonConfig = generateSingBoxConfig(
      parsed,
      splitConfig,
      inboundTag: inboundTag,
      interfaceName: interfaceName,
      addresses: interfaceAddresses,
      tunStack: Platform.isAndroid ? 'gvisor' : 'system',
      enableApplicationRules: Platform.isWindows,
      hasAndroidPackageRules: Platform.isAndroid && androidPackages.isNotEmpty,
      autoDetectInterface: !Platform.isAndroid,
      smartRouting: splitConfig.smartRouting && !useSmartEngineRules,
      smartDomains: splitConfig.smartRouting && !useSmartEngineRules
          ? splitConfig.smartDomains
          : const <String>[],
      extraRouteRules: extraRouteRules,
      dpiEvasionConfig: dpiEvasionConfig,
      clashApiPort: Platform.isWindows ? _clashApiPort : null,
    );
    _generatedConfig = jsonConfig;
    _configFile = null;

    if (Platform.isAndroid) {
      _notifyStatus('Запрос разрешения VPN');
      final granted = await _androidController.prepareVpn();
      if (!granted) {
        return SingBoxStartResult.failure('Разрешение отклонено пользователем');
      }

      final includePackages = splitConfig.mode == 'whitelist'
          ? androidPackages
          : <String>[];
      final excludePackages = splitConfig.mode == 'blacklist'
          ? androidPackages
          : <String>[];

      _notifyStatus('Запуск Libbox сервиса');
      await _androidController.startVpn(
        jsonConfig,
        includePackages: includePackages.isEmpty ? null : includePackages,
        excludePackages: excludePackages.isEmpty ? null : excludePackages,
      );
      _androidConnected = true;
      _notifyStatus('Libbox сервис запущен');
      unawaited(_warmupConnection());
      return SingBoxStartResult.success();
    }

    _notifyStatus('Поиск sing-box');
    final exePath = await _binaryManager.resolveExecutable();
    if (exePath == null) {
      return SingBoxStartResult.failure('Не найден исполняемый файл sing-box');
    }

    final tempDir = await Directory.systemTemp.createTemp('singbox_cfg_');
    final cfgFile = File('${tempDir.path}/config.json');
    await cfgFile.writeAsString(jsonConfig);
    _configFile = cfgFile;

    _notifyStatus('Запуск процесса');
    try {
      await _terminateExistingProcesses();
      final environment = Map<String, String>.from(Platform.environment);
      if (winDivertPaths != null && winDivertPaths.directory.isNotEmpty) {
        final dllDir = winDivertPaths.directory;
        final existingPath = environment['PATH'];
        environment['PATH'] = (existingPath == null || existingPath.isEmpty)
            ? dllDir
            : '$dllDir;$existingPath';
      }

      const maxAttempts = 2;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        final process = await Process.start(exePath, [
          'run',
          '-c',
          cfgFile.path,
        ], environment: environment);
        _process = process;
        _attachProcessHandlers(process, interfaceName);
        final startupError = await _verifyStartup(process, interfaceName);
        if (startupError == null) {
          _notifyStatus('Подключено (TUN: $interfaceName)');
          unawaited(_warmupConnection());
          return SingBoxStartResult.success();
        }

        await _forceStopProcess(process);
        await _teardownProcess();
        final logs = await _tunGuard.cleanupAdapter(interfaceName);
        _emitLogs(logs);
        if (attempt < maxAttempts) {
          await Future.delayed(const Duration(milliseconds: 900));
          continue;
        }
        return SingBoxStartResult.failure(startupError);
      }
      return SingBoxStartResult.failure('Ошибка запуска: неизвестная ошибка');
    } catch (e) {
      return SingBoxStartResult.failure('Ошибка запуска: $e');
    }
  }

  Future<void> _terminateExistingProcesses() async {
    if (!Platform.isWindows) return;
    try {
      await Process.run('taskkill', ['/F', '/IM', 'sing-box.exe']);
    } catch (_) {
      // Best-effort cleanup before starting a new instance.
    }
  }

  Future<void> disconnect({
    void Function(String status)? onStatus,
    void Function(String log)? onLog,
  }) async {
    _statusSink = onStatus ?? _statusSink;
    _logSink = onLog ?? _logSink;

    if (Platform.isAndroid) {
      if (!_androidConnected) return;
      _notifyStatus('Остановка сервиса...');
      await _androidController.stopVpn();
      _androidConnected = false;
      _notifyStatus('Остановлено');
      return;
    }

    final process = _process;
    if (process == null) return;

    _notifyStatus('Остановка...');
    await _forceStopProcess(process);

    await Future.delayed(const Duration(seconds: 1));
    await _teardownProcess();
    final interfaceName = _activeInterfaceName;
    _activeInterfaceName = null;
    if (interfaceName != null) {
      final logs = await _tunGuard.cleanupAdapter(interfaceName);
      _emitLogs(logs);
    }
    _notifyStatus('Остановлено');
  }

  Future<void> forceTerminate() async {
    if (Platform.isAndroid) {
      if (_androidConnected) {
        await _androidController.stopVpn();
        _androidConnected = false;
      }
      return;
    }

    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/F', '/IM', 'sing-box.exe']);
      } catch (_) {
        // Best-effort cleanup for stray sing-box processes.
      }
    }

    final process = _process;
    if (process == null) return;

    await _forceStopProcess(process);
    await _teardownProcess();
    final interfaceName = _activeInterfaceName;
    _activeInterfaceName = null;
    if (interfaceName != null) {
      final logs = await _tunGuard.cleanupAdapter(interfaceName);
      _emitLogs(logs);
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _teardownProcess();
  }

  void _attachProcessHandlers(Process process, String interfaceName) {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();

    _stdoutSub = process.stdout.transform(SystemEncoding().decoder).listen((
      data,
    ) {
      _emitChunk(data, isError: false);
    });
    _stderrSub = process.stderr.transform(SystemEncoding().decoder).listen((
      data,
    ) {
      _emitChunk(data, isError: true);
    });

    process.exitCode.then((code) async {
      await _teardownProcess();
      if (code == 1 && _accessDeniedDetected) {
        _notifyStatus('❌ Ошибка доступа - запустите от администратора');
      } else {
        _notifyStatus('Процесс завершён (код $code)');
      }

      if (_activeInterfaceName == interfaceName) {
        _activeInterfaceName = null;
        final logs = await _tunGuard.cleanupAdapter(interfaceName);
        _emitLogs(logs);
      }
    });
  }

  Future<void> _teardownProcess() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _process = null;
  }

  Future<int?> fetchTrafficBps() async {
    if (!Platform.isWindows) return null;
    if (_process == null) return null;
    final client = HttpClient();
    client.connectionTimeout = const Duration(milliseconds: 800);
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$_clashApiPort/traffic'))
          .timeout(const Duration(milliseconds: 800));
      final response = await request.close().timeout(
        const Duration(milliseconds: 800),
      );
      if (response.statusCode != 200) return null;
      final body = await response.transform(SystemEncoding().decoder).join();
      final data = jsonDecode(body);
      if (data is Map) {
        final down = data['down'];
        final up = data['up'];
        if (down is num && up is num) {
          return (down + up).round();
        }
      }
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
    return null;
  }

  Future<void> startTrafficStream() async {
    if (!Platform.isWindows) return;
    if (_trafficSocket != null) return;
    try {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:$_clashApiPort/traffic',
      );
      _trafficSocket = socket;
      _trafficSocketSub = socket.listen(
        (event) {
          try {
            final data = jsonDecode(event as String);
            if (data is Map) {
              final down = data['down'];
              final up = data['up'];
              if (down is num && up is num) {
                _trafficController.add((down + up).round());
              }
            }
          } catch (_) {
            // ignore malformed traffic payloads
          }
        },
        onError: (_) {
          _trafficSocket = null;
        },
        onDone: () {
          _trafficSocket = null;
        },
        cancelOnError: true,
      );
    } catch (_) {
      _trafficSocket = null;
    }
  }

  Future<void> stopTrafficStream() async {
    await _trafficSocketSub?.cancel();
    _trafficSocketSub = null;
    await _trafficSocket?.close();
    _trafficSocket = null;
  }

  void _emitChunk(String chunk, {required bool isError}) {
    final lines = chunk.split(RegExp(r'[\r\n]+'));
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      _rememberLogLine(line, isError: isError);
      if (isError &&
          (line.contains('Access is denied') ||
              line.contains('configure tun interface'))) {
        _accessDeniedDetected = true;
        _notifyStatus(
          '❌ Нужны права администратора! Запустите приложение от имени администратора',
        );
      }
      _logSink?.call(isError ? '[ERR] $line' : line);
    }
  }

  void _emitLogs(Iterable<String> logs) {
    for (final line in logs) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      _logSink?.call(trimmed);
    }
  }

  void _rememberLogLine(String line, {required bool isError}) {
    _recentLogs.add(line);
    if (_recentLogs.length > 80) {
      _recentLogs.removeAt(0);
    }
    if (isError) {
      _lastStartError = line;
    }
  }

  Future<void> _forceStopProcess(Process process) async {
    if (process.pid == 0) return;
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
    }
  }

  Future<String?> _verifyStartup(Process process, String interfaceName) async {
    if (_startupCheckInProgress) return null;
    _startupCheckInProgress = true;
    try {
      try {
        final exitCode = await process.exitCode.timeout(
          const Duration(milliseconds: 800),
        );
        final hint = _lastStartError ?? (_recentLogs.isNotEmpty ? _recentLogs.last : null);
        final suffix = hint == null ? '' : ' ($hint)';
        return 'sing-box exited early (code $exitCode)$suffix';
      } on TimeoutException {
        // Process is still alive. Continue with adapter check.
      }
      if (Platform.isWindows) {
        final adapterUp = await _tunGuard.waitForAdapterUp(
          interfaceName,
          timeout: const Duration(seconds: 4),
        );
        if (!adapterUp) {
          final hint = _lastStartError ?? (_recentLogs.isNotEmpty ? _recentLogs.last : null);
          final suffix = hint == null ? '' : ' ($hint)';
          return 'TUN adapter did not come up$suffix';
        }
      }
      return null;
    } finally {
      _startupCheckInProgress = false;
    }
  }

  Future<void> _warmupConnection() async {
    // Расширенный прогрев с DNS-предзагрузкой популярных доменов.
    const warmupDomains = [
      // Основные CDN
      'google.com',
      'youtube.com',
      'gstatic.com',
      'ytimg.com',
      'cloudflare.com',
      'fastly.net',
      // Популярные сервисы
      'github.com',
      'discord.com',
      'telegram.org',
      'facebook.com',
      'instagram.com',
      'twitter.com',
      'reddit.com',
      'netflix.com',
      'spotify.com',
      'amazon.com',
      'apple.com',
      'microsoft.com',
    ];

    // DNS-предзагрузка без HTTP-запросов (быстрее)
    for (final domain in warmupDomains) {
      unawaited(_preloadDns(domain));
    }

    // Минимальный HTTP-прогрев, чтобы гарантированно создать реальный трафик через TUN.
    // Это помогает диагностике (появятся outbound/handshake логи) и сразу отмечает клиента "online" на панели.
    const warmupHttpDomains = ['cloudflare.com', 'www.microsoft.com'];
    for (final domain in warmupHttpDomains) {
      unawaited(_warmupDomain(domain));
    }
  }

  Future<void> _preloadDns(String domain) async {
    try {
      await InternetAddress.lookup(
        domain,
      ).timeout(const Duration(milliseconds: 800));
    } catch (_) {
      // Тихое игнорирование ошибок DNS-прогрева.
    }
  }

  Future<void> _warmupDomain(String domain) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(milliseconds: 1200);
    client.badCertificateCallback = (cert, host, port) => false;

    try {
      final request = await client
          .openUrl('HEAD', Uri.https(domain, '/'))
          .timeout(const Duration(milliseconds: 1200));
      await request.close().timeout(const Duration(milliseconds: 1200));
    } catch (_) {
      // Игнорируем ошибки прогрева, чтобы не мешать основному подключению.
    } finally {
      client.close(force: true);
    }
  }

  void _notifyStatus(String value) {
    _statusSink?.call(value);
  }

  List<String> _extractAndroidPackages(SplitTunnelConfig config) {
    final packages = <String>{};
    for (final entry in config.applications) {
      var value = entry.trim();
      if (value.isEmpty) continue;
      if (value.startsWith('package:')) {
        value = value.substring('package:'.length).trim();
      }
      if (value.isEmpty) continue;
      packages.add(value);
    }
    return packages.toList();
  }
}
