import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/split_tunnel_config.dart';
import 'android_vpn_controller.dart';
import 'singbox_binary_manager.dart';
import 'windows_tun_guard.dart';
import 'wintun_manager.dart';
import '../services/smart_route_engine.dart';
import '../vless/config_generator.dart';
import '../vless/vless_parser.dart';
import 'dpi_evasion_config.dart';

typedef SingBoxProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    });
typedef SingBoxProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

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
    SingBoxProcessStarter? processStarter,
    SingBoxProcessRunner? processRunner,
    bool? isWindowsOverride,
    bool? isAndroidOverride,
  }) : _wintunManager = wintunManager ?? WintunManager(),
       _tunGuard = tunGuard ?? WindowsTunGuard(),
       _binaryManager = binaryManager ?? SingBoxBinaryManager(),
       _androidController = androidController ?? AndroidVpnController(),
       _processStarter = processStarter ?? _defaultProcessStarter,
       _processRunner = processRunner ?? _defaultProcessRunner,
       _isWindowsOverride = isWindowsOverride,
       _isAndroidOverride = isAndroidOverride;

  final WintunManager _wintunManager;
  final WindowsTunGuard _tunGuard;
  final SingBoxBinaryManager _binaryManager;
  final AndroidVpnController _androidController;
  final SingBoxProcessStarter _processStarter;
  final SingBoxProcessRunner _processRunner;
  final bool? _isWindowsOverride;
  final bool? _isAndroidOverride;

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
  File? _connectionLogFile;
  final List<String> _pendingConnectionLogLines = <String>[];
  Timer? _connectionLogFlushTimer;
  bool _connectionLogFlushInProgress = false;
  int _droppedConnectionLogLines = 0;
  bool _connectionLogThrottleMarkerQueued = false;
  int _sessionEpoch = 0;
  int? _activeConnectionToken;
  final Map<int, String> _sessionInterfaces = <int, String>{};
  final Set<int> _cleanupInProgressTokens = <int>{};
  static const int _maxWindowsAutoRecoverAttempts = 3;
  static const int _clashApiPort = 9090;
  static const int _connectionLogFlushMs = 200;
  static const int _maxPendingConnectionLogLines = 1000;

  void Function(String status)? _statusSink;
  void Function(String log)? _logSink;

  VlessLink? get parsedLink => _parsedLink;
  File? get configFile => _configFile;
  String? get generatedConfig => _generatedConfig;
  int get clashApiPort => _clashApiPort;
  Stream<int> get trafficStream => _trafficController.stream;
  @visibleForTesting
  int? get debugActiveConnectionToken => _activeConnectionToken;

  String get interfaceLabel {
    if (_isWindows) {
      return _activeInterfaceName ?? WindowsTunGuard.defaultInterfaceName;
    }
    return 'Android VPN';
  }

  bool get isRunning => _isAndroid ? _androidConnected : _process != null;

  Future<bool> isWintunAvailable() => _wintunManager.isWintunAvailable();

  Future<bool> syncRuntimeState() async {
    if (!_isAndroid) {
      return isRunning;
    }
    try {
      _androidConnected = await _androidController.isRunning();
    } catch (_) {
      _androidConnected = false;
    }
    return _androidConnected;
  }

  bool get _isWindows => _isWindowsOverride ?? Platform.isWindows;
  bool get _isAndroid => _isAndroidOverride ?? Platform.isAndroid;

  Future<SingBoxStartResult> connect({
    required String rawUri,
    required SplitTunnelConfig splitConfig,
    bool developerMode = false,
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
    await _createConnectionLogFile();

    final trimmed = rawUri.trim();
    if (trimmed.isEmpty) {
      return SingBoxStartResult.failure('Ошибка: пустой VLESS URI');
    }

    final parsed = parseVlessUri(trimmed);
    if (parsed == null) {
      return SingBoxStartResult.failure('Ошибка: неверный формат VLESS URI');
    }
    _parsedLink = parsed;
    if (!_isWindows && !_isAndroid) {
      return SingBoxStartResult.failure('Платформа не поддерживается');
    }

    final androidPackages = _isAndroid
        ? _extractAndroidPackages(splitConfig)
        : <String>[];

    final extraRouteRules = <Map<String, dynamic>>[];
    final extraOutbounds = <Map<String, dynamic>>[];
    final extraInbounds = <Map<String, dynamic>>[];
    List<Map<String, dynamic>>? dnsServers;
    String? dnsFinalTag;
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

    if (_isAndroid) {
      _notifyStatus('Генерация конфига');
      final jsonConfig = _buildConfigJson(
        parsed: parsed,
        splitConfig: splitConfig,
        inboundTag: WindowsTunGuard.defaultInboundTag,
        interfaceName: WindowsTunGuard.defaultInterfaceName,
        interfaceAddresses: const ['172.19.0.1/30'],
        useSmartEngineRules: useSmartEngineRules,
        extraRouteRules: extraRouteRules,
        extraOutbounds: extraOutbounds,
        extraInbounds: extraInbounds,
        dnsServers: dnsServers,
        dnsFinalTag: dnsFinalTag,
        dpiEvasionConfig: dpiEvasionConfig,
        developerMode: developerMode,
      );
      _generatedConfig = jsonConfig;
      _configFile = null;
      _notifyStatus('Запрос разрешения VPN');
      bool granted;
      try {
        granted = await _androidController.prepareVpn();
      } catch (e) {
        return SingBoxStartResult.failure(
          'Не удалось запросить разрешение VPN: $e',
        );
      }
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
      try {
        await _androidController.startVpn(
          jsonConfig,
          includePackages: includePackages.isEmpty ? null : includePackages,
          excludePackages: excludePackages.isEmpty ? null : excludePackages,
        );
      } catch (e) {
        return SingBoxStartResult.failure(
          'Не удалось запустить Android VPN сервис: $e',
        );
      }
      final running = await _waitForAndroidServiceStartup();
      _androidConnected = running;
      if (!running) {
        return SingBoxStartResult.failure(
          'Android VPN сервис не запустился (проверьте совместимость конфигурации)',
        );
      }
      _notifyStatus('Libbox сервис запущен');
      unawaited(_warmupConnection());
      return SingBoxStartResult.success();
    }

    return _connectWindowsWithAutoRecover(
      parsed: parsed,
      splitConfig: splitConfig,
      useSmartEngineRules: useSmartEngineRules,
      extraRouteRules: extraRouteRules,
      extraOutbounds: extraOutbounds,
      extraInbounds: extraInbounds,
      dnsServers: dnsServers,
      dnsFinalTag: dnsFinalTag,
      dpiEvasionConfig: dpiEvasionConfig,
      developerMode: developerMode,
    );
  }

  Future<SingBoxStartResult> _connectWindowsWithAutoRecover({
    required VlessLink parsed,
    required SplitTunnelConfig splitConfig,
    required bool useSmartEngineRules,
    required List<Map<String, dynamic>> extraRouteRules,
    required List<Map<String, dynamic>> extraOutbounds,
    required List<Map<String, dynamic>> extraInbounds,
    required List<Map<String, dynamic>>? dnsServers,
    required String? dnsFinalTag,
    required DpiEvasionConfig dpiEvasionConfig,
    required bool developerMode,
  }) async {
    _notifyStatus('Поиск sing-box');
    final exePath = await _binaryManager.resolveExecutable();
    if (exePath == null) {
      return SingBoxStartResult.failure('Не найден исполняемый файл sing-box');
    }

    if (_activeConnectionToken != null) {
      await _cleanupSessionToken(
        _activeConnectionToken!,
        reason: 'pre-connect',
      );
    }

    await _terminateExistingProcesses();
    final environment = Map<String, String>.from(Platform.environment);
    String? lastError;

    for (
      var attempt = 1;
      attempt <= _maxWindowsAutoRecoverAttempts;
      attempt++
    ) {
      final token = ++_sessionEpoch;
      _activeConnectionToken = token;
      _notifyStatus(
        'Подключение... попытка $attempt/$_maxWindowsAutoRecoverAttempts',
      );
      _appendConnectionLog(
        '\n=== New Connection Attempt ===\n'
        'token=$token\n'
        'attempt=$attempt/$_maxWindowsAutoRecoverAttempts\n',
      );

      final plan = await _tunGuard.prepare();
      _emitLogs(plan.logs);
      if (!plan.success) {
        await _cleanupSessionToken(token, reason: 'prepare-failed');
        final message = plan.requiresElevation
            ? '❌ Нужны права администратора для управления TUN интерфейсом'
            : (plan.error ?? 'Не удалось подготовить TUN интерфейс');
        return SingBoxStartResult.failure(
          message,
          requiresAdmin: plan.requiresElevation,
        );
      }

      final stale = plan.staleAdapters
          .where((name) => name != plan.interfaceName)
          .toList();
      if (stale.isNotEmpty) {
        _appendConnectionLog(
          '[token=$token] Cleaning stale adapters: ${stale.join(', ')}',
        );
        final cleanup = await _tunGuard.cleanupAdapters(stale);
        _emitLogs(cleanup.logs);
        if (!cleanup.success) {
          lastError =
              'Не удалось удалить старые TUN адаптеры: '
              '${cleanup.stillPresentAdapters.join(', ')}';
          _appendConnectionLog(
            '[token=$token] auto-recover attempt failed: stale adapters '
            '${cleanup.stillPresentAdapters.join(', ')}',
          );
          await _cleanupSessionToken(token, reason: 'stale-cleanup-failed');
          if (attempt < _maxWindowsAutoRecoverAttempts) {
            _notifyStatus(
              'Автовосстановление... попытка ${attempt + 1}/$_maxWindowsAutoRecoverAttempts',
            );
            continue;
          }
          return SingBoxStartResult.failure(lastError);
        }
      }

      _activeInterfaceName = plan.interfaceName;
      _sessionInterfaces[token] = plan.interfaceName;
      _notifyStatus('Генерация конфига');
      final jsonConfig = _buildConfigJson(
        parsed: parsed,
        splitConfig: splitConfig,
        inboundTag: plan.inboundTag,
        interfaceName: plan.interfaceName,
        interfaceAddresses: plan.addresses,
        useSmartEngineRules: useSmartEngineRules,
        extraRouteRules: extraRouteRules,
        extraOutbounds: extraOutbounds,
        extraInbounds: extraInbounds,
        dnsServers: dnsServers,
        dnsFinalTag: dnsFinalTag,
        dpiEvasionConfig: dpiEvasionConfig,
        developerMode: developerMode,
      );
      _generatedConfig = jsonConfig;

      final tempDir = await Directory.systemTemp.createTemp('singbox_cfg_');
      final cfgFile = File('${tempDir.path}/config.json');
      await cfgFile.writeAsString(jsonConfig);
      _configFile = cfgFile;

      _notifyStatus('Запуск процесса');
      _appendConnectionLog(
        '[token=$token] auto-recover attempt started '
        'with interface=${plan.interfaceName}',
      );
      try {
        final process = await _processStarter(exePath, [
          'run',
          '-c',
          cfgFile.path,
        ], environment: environment);
        _process = process;
        _attachProcessHandlers(process, plan.interfaceName, token);
        final startupError = await _verifyStartup(process, plan.interfaceName);
        if (startupError == null) {
          _notifyStatus('Подключено (TUN: ${plan.interfaceName})');
          _appendConnectionLog(
            '[token=$token] auto-recover attempt succeeded '
            'interface=${plan.interfaceName}',
          );
          unawaited(_warmupConnection());
          return SingBoxStartResult.success();
        }

        lastError = startupError;
        final failureClass = _classifyStartupFailure(startupError);
        _appendConnectionLog(
          '[token=$token] auto-recover attempt failed '
          'class=${failureClass.name} error=$startupError',
        );

        await _forceStopProcess(process);
        await _teardownProcess();
        await _cleanupSessionToken(token, reason: 'startup-failed');

        if (failureClass == _StartupFailureClass.requiresAdmin ||
            _accessDeniedDetected) {
          return SingBoxStartResult.failure(startupError, requiresAdmin: true);
        }

        if (failureClass == _StartupFailureClass.fatal ||
            attempt >= _maxWindowsAutoRecoverAttempts) {
          return SingBoxStartResult.failure(startupError);
        }

        _notifyStatus(
          'Автовосстановление... попытка ${attempt + 1}/$_maxWindowsAutoRecoverAttempts',
        );
      } catch (e) {
        lastError = 'Ошибка запуска: $e';
        _appendConnectionLog('[token=$token] process start exception: $e');
        await _teardownProcess();
        await _cleanupSessionToken(token, reason: 'process-start-exception');
        if (attempt >= _maxWindowsAutoRecoverAttempts) {
          return SingBoxStartResult.failure(lastError);
        }
      }
    }

    return SingBoxStartResult.failure(
      lastError ?? 'Ошибка запуска: неизвестная ошибка',
    );
  }

  String _buildConfigJson({
    required VlessLink parsed,
    required SplitTunnelConfig splitConfig,
    required String inboundTag,
    required String interfaceName,
    required List<String> interfaceAddresses,
    required bool useSmartEngineRules,
    required List<Map<String, dynamic>> extraRouteRules,
    required List<Map<String, dynamic>> extraOutbounds,
    required List<Map<String, dynamic>> extraInbounds,
    required List<Map<String, dynamic>>? dnsServers,
    required String? dnsFinalTag,
    required DpiEvasionConfig dpiEvasionConfig,
    required bool developerMode,
  }) {
    return generateSingBoxConfig(
      parsed,
      splitConfig,
      inboundTag: inboundTag,
      interfaceName: interfaceName,
      addresses: interfaceAddresses,
      tunStack: _isAndroid ? 'gvisor' : 'system',
      enableApplicationRules: _isWindows,
      hasAndroidPackageRules: _isAndroid && splitConfig.applications.isNotEmpty,
      autoDetectInterface: !_isAndroid,
      smartRouting: splitConfig.smartRouting && !useSmartEngineRules,
      smartDomains: splitConfig.smartRouting && !useSmartEngineRules
          ? splitConfig.smartDomains
          : const <String>[],
      extraRouteRules: extraRouteRules,
      extraOutbounds: extraOutbounds,
      extraInbounds: extraInbounds,
      dnsServers: dnsServers,
      dnsFinalTag: dnsFinalTag,
      dpiEvasionConfig: dpiEvasionConfig,
      allowLegacyTlsFragmentField: !_isAndroid,
      allowTransportFragment: !_isAndroid,
      clashApiPort: _isWindows ? _clashApiPort : null,
      logLevel: developerMode ? 'debug' : 'info',
    );
  }

  Future<bool> _waitForAndroidServiceStartup() async {
    if (!_isAndroid) return true;
    const attempts = 8;
    for (var i = 0; i < attempts; i++) {
      final running = await _androidController.isRunning();
      if (running) return true;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<bool> _waitForAndroidServiceStop({int attempts = 16}) async {
    if (!_isAndroid) return true;
    for (var i = 0; i < attempts; i++) {
      final running = await _androidController.isRunning();
      if (!running) return true;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<void> _terminateExistingProcesses() async {
    if (!_isWindows) return;
    try {
      await _processRunner('taskkill', ['/F', '/IM', 'sing-box.exe']);
      await Future.delayed(const Duration(milliseconds: 500));
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

    if (_isAndroid) {
      final running = await syncRuntimeState();
      if (!running) {
        _notifyStatus('Остановлено');
        return;
      }
      _notifyStatus('Остановка сервиса...');
      const stopAttempts = 2;
      var stopped = false;
      for (var attempt = 1; attempt <= stopAttempts; attempt++) {
        _logSink?.call('[DBG] Android stop attempt $attempt/$stopAttempts');
        try {
          await _androidController.stopVpn();
        } catch (e) {
          _logSink?.call('[ERR] stopVpn failed (attempt $attempt): $e');
        }
        stopped = await _waitForAndroidServiceStop();
        if (stopped) {
          break;
        }
      }
      _androidConnected = !stopped;
      if (stopped) {
        _notifyStatus('Остановлено');
      } else {
        _notifyStatus('Android VPN сервис все еще активен');
      }
      return;
    }

    final process = _process;
    _notifyStatus('Остановка...');
    if (process != null) {
      await _forceStopProcess(process);
      await Future.delayed(const Duration(milliseconds: 400));
    }
    await _teardownProcess();

    final activeToken = _activeConnectionToken;
    if (activeToken != null) {
      await _cleanupSessionToken(activeToken, reason: 'manual-disconnect');
    } else if (_activeInterfaceName != null) {
      final cleanup = await _tunGuard.cleanupAdapter(_activeInterfaceName);
      _emitLogs(cleanup.logs);
      _activeInterfaceName = null;
    }
    await _flushConnectionLog(force: true);
    _notifyStatus('Остановлено');
  }

  Future<void> forceTerminate() async {
    if (_isAndroid) {
      final running = await syncRuntimeState();
      if (running) {
        const stopAttempts = 2;
        for (var attempt = 1; attempt <= stopAttempts; attempt++) {
          try {
            await _androidController.stopVpn();
          } catch (_) {
            // Best-effort cleanup for Android service.
          }
          final stopped = await _waitForAndroidServiceStop();
          if (stopped) {
            _androidConnected = false;
            return;
          }
        }
      }
      final stopped = await _waitForAndroidServiceStop();
      _androidConnected = !stopped;
      return;
    }

    if (_isWindows) {
      try {
        await _processRunner('taskkill', ['/F', '/IM', 'sing-box.exe']);
      } catch (_) {
        // Best-effort cleanup for stray sing-box processes.
      }
    }

    final process = _process;
    if (process != null) {
      await _forceStopProcess(process);
      await _teardownProcess();
    }
    final token = _activeConnectionToken;
    if (token != null) {
      await _cleanupSessionToken(token, reason: 'force-terminate');
    } else if (_activeInterfaceName != null) {
      final cleanup = await _tunGuard.cleanupAdapter(_activeInterfaceName);
      _emitLogs(cleanup.logs);
      _activeInterfaceName = null;
    }
    await _flushConnectionLog(force: true);
  }

  Future<void> dispose() async {
    await disconnect();
    await _teardownProcess();
    await _flushConnectionLog(force: true);
  }

  void _attachProcessHandlers(
    Process process,
    String interfaceName,
    int token,
  ) {
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
      if (_process != process) {
        return;
      }
      await _teardownProcess();
      if (code == 1 && _accessDeniedDetected) {
        _notifyStatus('❌ Ошибка доступа - запустите от администратора');
      } else {
        _notifyStatus('Процесс завершён (код $code)');
      }
      await _cleanupSessionToken(token, reason: 'process-exit');
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
    if (!_isWindows) return null;
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
    if (!_isWindows) return;
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
              line.toLowerCase().contains('permission denied'))) {
        _accessDeniedDetected = true;
        _notifyStatus(
          '❌ Нужны права администратора! Запустите приложение от имени администратора',
        );
      }
      final payload = isError ? '[ERR] $line' : line;
      _logSink?.call(payload);
      _appendConnectionLog(payload);
    }
  }

  void _emitLogs(Iterable<String> logs) {
    for (final line in logs) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      _logSink?.call(trimmed);
      _appendConnectionLog(trimmed);
    }
  }

  void _appendConnectionLog(String log) {
    if (_connectionLogFile == null) return;
    final trimmed = log.trim();
    if (trimmed.isEmpty) return;
    if (_pendingConnectionLogLines.length >= _maxPendingConnectionLogLines) {
      _droppedConnectionLogLines++;
      _connectionLogThrottleMarkerQueued = true;
      _scheduleConnectionLogFlush();
      return;
    }
    _pendingConnectionLogLines.add(trimmed);
    _scheduleConnectionLogFlush();
  }

  Future<void> _createConnectionLogFile() async {
    try {
      await _flushConnectionLog(force: true);
      _connectionLogFlushTimer?.cancel();
      _connectionLogFlushTimer = null;
      final now = DateTime.now();
      final dateStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}';
      final logsDir = Directory('${Directory.systemTemp.path}/neuravpn_logs');
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }
      final logFile = File('${logsDir.path}/connection_$dateStr.txt');
      await logFile.create();
      await logFile.writeAsString(
        '=== Connection Attempt Log ===\nStart Time: $now\n\n',
      );
      _connectionLogFile = logFile;
      _appendConnectionLog('Log file created: ${logFile.path}');
    } catch (e) {
      // Error creating connection log - ignore
    }
  }

  void _scheduleConnectionLogFlush() {
    if (_connectionLogFlushTimer != null) return;
    _connectionLogFlushTimer = Timer(
      const Duration(milliseconds: _connectionLogFlushMs),
      () {
        _connectionLogFlushTimer = null;
        unawaited(_flushConnectionLog());
      },
    );
  }

  Future<void> _flushConnectionLog({bool force = false}) async {
    if (_connectionLogFile == null) return;
    if (_connectionLogFlushInProgress) {
      if (!force) return;
      while (_connectionLogFlushInProgress) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }

    if (!force &&
        _pendingConnectionLogLines.isEmpty &&
        !_connectionLogThrottleMarkerQueued) {
      return;
    }

    _connectionLogFlushInProgress = true;
    try {
      final lines = <String>[];
      if (_connectionLogThrottleMarkerQueued &&
          _droppedConnectionLogLines > 0) {
        lines.add(
          '... connection log throttled: '
          '$_droppedConnectionLogLines lines dropped ...',
        );
      }
      if (_pendingConnectionLogLines.isNotEmpty) {
        lines.addAll(_pendingConnectionLogLines);
        _pendingConnectionLogLines.clear();
      }
      _connectionLogThrottleMarkerQueued = false;
      _droppedConnectionLogLines = 0;

      if (lines.isEmpty) return;
      final payload = '${lines.join('\n')}\n';
      await _connectionLogFile!.writeAsString(
        payload,
        mode: FileMode.append,
        flush: force,
      );
    } catch (_) {
      // Ignore file write errors
    } finally {
      _connectionLogFlushInProgress = false;
    }

    if (force &&
        (_pendingConnectionLogLines.isNotEmpty ||
            _connectionLogThrottleMarkerQueued)) {
      await _flushConnectionLog(force: true);
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

  Future<void> _cleanupSessionToken(int token, {required String reason}) async {
    if (!_cleanupInProgressTokens.add(token)) {
      _appendConnectionLog('[token=$token] cleanup skipped (already running)');
      return;
    }
    try {
      final interfaceName =
          _sessionInterfaces[token] ??
          (_activeConnectionToken == token ? _activeInterfaceName : null);
      _appendConnectionLog(
        '[token=$token] cleanup started reason=$reason interface=${interfaceName ?? 'unknown'}',
      );
      if (_isWindows && interfaceName != null) {
        final cleanup = await _tunGuard.cleanupAdapter(interfaceName);
        _emitLogs(cleanup.logs);
      }
      _sessionInterfaces.remove(token);
      if (_activeConnectionToken == token) {
        _activeConnectionToken = null;
        _activeInterfaceName = null;
      }
      _appendConnectionLog('[token=$token] cleanup completed reason=$reason');
    } finally {
      _cleanupInProgressTokens.remove(token);
    }
  }

  _StartupFailureClass _classifyStartupFailure(String message) {
    final normalized = message.toLowerCase();
    if (_accessDeniedDetected ||
        normalized.contains('access is denied') ||
        normalized.contains('администратор')) {
      return _StartupFailureClass.requiresAdmin;
    }
    if (normalized.contains('already exists') ||
        normalized.contains(
          'cannot create a file when that file already exists',
        ) ||
        normalized.contains('configure tun interface')) {
      return _StartupFailureClass.recoverableTunCollision;
    }
    if (normalized.contains('tun adapter did not come up') ||
        normalized.contains('timed out')) {
      return _StartupFailureClass.recoverableTunTimeout;
    }
    return _StartupFailureClass.fatal;
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
        final hint =
            _lastStartError ??
            (_recentLogs.isNotEmpty ? _recentLogs.last : null);
        final suffix = hint == null ? '' : ' ($hint)';
        _appendConnectionLog(
          'ERROR: sing-box exited early (code $exitCode)$suffix',
        );
        return 'sing-box exited early (code $exitCode)$suffix';
      } on TimeoutException {
        // Process is still alive. Continue with adapter check.
      }
      if (_isWindows) {
        _appendConnectionLog('Waiting for TUN adapter to come up...');
        final adapterUp = await _tunGuard.waitForAdapterUp(
          interfaceName,
          timeout: const Duration(seconds: 40),
        );
        if (!adapterUp) {
          final hint =
              _lastStartError ??
              (_recentLogs.isNotEmpty ? _recentLogs.last : null);
          final suffix = hint == null ? '' : ' ($hint)';
          _appendConnectionLog('ERROR: TUN adapter did not come up$suffix');
          return 'TUN adapter did not come up$suffix';
        }
        _appendConnectionLog('TUN adapter is up and ready');
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

  @visibleForTesting
  void debugSetActiveSessionForTest({
    required int token,
    required String interfaceName,
  }) {
    _activeConnectionToken = token;
    _activeInterfaceName = interfaceName;
    _sessionInterfaces[token] = interfaceName;
  }

  static Future<Process> _defaultProcessStarter(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) {
    return Process.start(executable, arguments, environment: environment);
  }

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(executable, arguments);
  }
}

enum _StartupFailureClass {
  recoverableTunCollision,
  recoverableTunTimeout,
  requiresAdmin,
  fatal,
}
