import 'dart:async';
import 'dart:io';

import '../models/split_tunnel_config.dart';
import 'android_vpn_controller.dart';
import 'singbox_binary_manager.dart';
import 'windows_tun_guard.dart';
import 'windivert_manager.dart';
import 'wintun_manager.dart';
import '../vless/config_generator.dart';
import '../vless/vless_parser.dart';

class SingBoxStartResult {
  final bool success;
  final String? errorMessage;
  final bool requiresAdmin;

  const SingBoxStartResult._({required this.success, this.errorMessage, this.requiresAdmin = false});

  factory SingBoxStartResult.success() => const SingBoxStartResult._(success: true);

  factory SingBoxStartResult.failure(String message, {bool requiresAdmin = false}) => SingBoxStartResult._(
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
    })  : _wintunManager = wintunManager ?? WintunManager(),
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

  String? _activeInterfaceName;
  File? _configFile;
  String? _generatedConfig;
  VlessLink? _parsedLink;

  void Function(String status)? _statusSink;
  void Function(String log)? _logSink;

  VlessLink? get parsedLink => _parsedLink;
  File? get configFile => _configFile;
  String? get generatedConfig => _generatedConfig;

  String get interfaceLabel {
    if (Platform.isWindows) {
      return _activeInterfaceName ?? WindowsTunGuard.defaultInterfaceName;
    }
    return 'Android VPN';
  }

  bool get isRunning => Platform.isAndroid ? _androidConnected : _process != null;

  Future<bool> isWintunAvailable() => _wintunManager.isWintunAvailable();

  Future<SingBoxStartResult> connect({
    required String rawUri,
    required SplitTunnelConfig splitConfig,
    void Function(String status)? onStatus,
    void Function(String log)? onLog,
  }) async {
    _statusSink = onStatus;
    _logSink = onLog;
    _accessDeniedDetected = false;

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
      _notifyStatus('Проверка TUN интерфейса');
      final guardResult = await _tunGuard.prepare();
      _emitLogs(guardResult.logs);

      if (!guardResult.success) {
        final message = guardResult.requiresElevation
            ? '❌ Нужны права администратора для управления TUN интерфейсом'
            : (guardResult.error ?? 'Не удалось подготовить TUN интерфейс');
        return SingBoxStartResult.failure(message, requiresAdmin: guardResult.requiresElevation);
      }

      inboundTag = guardResult.inboundTag;
      interfaceName = guardResult.interfaceName;
      interfaceAddresses = guardResult.addresses;
      _activeInterfaceName = interfaceName;

      if (guardResult.leftoverAdapters.isNotEmpty) {
        unawaited(_tunGuard.cleanupAdapters(guardResult.leftoverAdapters).then(_emitLogs));
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

    final androidPackages = Platform.isAndroid ? _extractAndroidPackages(splitConfig) : <String>[];

    _notifyStatus('Генерация конфига');
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
    );
    _generatedConfig = jsonConfig;
    _configFile = null;

    if (Platform.isAndroid) {
      _notifyStatus('Запрос разрешения VPN');
      final granted = await _androidController.prepareVpn();
      if (!granted) {
        return SingBoxStartResult.failure('Разрешение отклонено пользователем');
      }

      final includePackages = splitConfig.mode == 'whitelist' ? androidPackages : <String>[];
      final excludePackages = splitConfig.mode == 'blacklist' ? androidPackages : <String>[];

      _notifyStatus('Запуск Libbox сервиса');
      await _androidController.startVpn(
        jsonConfig,
        includePackages: includePackages.isEmpty ? null : includePackages,
        excludePackages: excludePackages.isEmpty ? null : excludePackages,
      );
      _androidConnected = true;
      _notifyStatus('Libbox сервис запущен');
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
      final environment = Map<String, String>.from(Platform.environment);
      if (winDivertPaths != null && winDivertPaths.directory.isNotEmpty) {
        final dllDir = winDivertPaths.directory;
        final existingPath = environment['PATH'];
        environment['PATH'] = (existingPath == null || existingPath.isEmpty)
          ? dllDir
          : '$dllDir;$existingPath';
      }

      final process = await Process.start(
        exePath,
        ['run', '-c', cfgFile.path],
        environment: environment,
      );
      _process = process;
      _attachProcessHandlers(process, interfaceName);
      _notifyStatus('Подключено (TUN: $interfaceName)');
      return SingBoxStartResult.success();
    } catch (e) {
      return SingBoxStartResult.failure('Ошибка запуска: $e');
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
    process.kill(ProcessSignal.sigterm);

    try {
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      if (exitCode == -1) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      await Future.delayed(const Duration(milliseconds: 500));
    }

    await Future.delayed(const Duration(seconds: 1));
    await _teardownProcess();
    _notifyStatus('Остановлено');
  }

  Future<void> dispose() async {
    await disconnect();
    await _teardownProcess();
  }

  void _attachProcessHandlers(Process process, String interfaceName) {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();

    _stdoutSub = process.stdout.transform(SystemEncoding().decoder).listen((data) {
      _emitChunk(data, isError: false);
    });
    _stderrSub = process.stderr.transform(SystemEncoding().decoder).listen((data) {
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

  void _emitChunk(String chunk, {required bool isError}) {
    final lines = chunk.split(RegExp(r'[\r\n]+'));
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (isError && (line.contains('Access is denied') || line.contains('configure tun interface'))) {
        _accessDeniedDetected = true;
        _notifyStatus('❌ Нужны права администратора! Запустите приложение от имени администратора');
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