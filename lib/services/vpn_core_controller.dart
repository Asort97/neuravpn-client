import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/split_tunnel_config.dart';
import 'android_vpn_controller.dart';
import 'vpn_core_binary_manager.dart';
import 'windows_tun_guard.dart';
import 'windows_vpn_core.dart';
import 'windows_xray_core.dart';
import 'windows_route_manager.dart';
import 'wintun_manager.dart';
import '../services/smart_route_engine.dart';
import '../vless/config_generator.dart';
import '../vless/vless_parser.dart';
import 'dpi_evasion_config.dart';

enum TrafficSamplingMode { stopped, foreground, background }

typedef VpnCoreProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    });
typedef VpnCoreProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class TrafficSample {
  const TrafficSample({required this.uplinkBps, required this.downlinkBps});

  final int uplinkBps;
  final int downlinkBps;

  int get totalBps => uplinkBps + downlinkBps;
}

class VpnCoreStartResult {
  final bool success;
  final String? errorMessage;
  final bool requiresAdmin;

  const VpnCoreStartResult._({
    required this.success,
    this.errorMessage,
    this.requiresAdmin = false,
  });

  factory VpnCoreStartResult.success() =>
      const VpnCoreStartResult._(success: true);

  factory VpnCoreStartResult.failure(
    String message, {
    bool requiresAdmin = false,
  }) => VpnCoreStartResult._(
    success: false,
    errorMessage: message,
    requiresAdmin: requiresAdmin,
  );
}

class VpnCoreController {
  static const bool _androidXrayExperimental = true;
  VpnCoreController({
    WintunManager? wintunManager,
    WindowsTunGuard? tunGuard,
    VpnCoreBinaryManager? binaryManager,
    AndroidVpnController? androidController,
    WindowsVpnCoreAdapter? windowsCoreAdapter,
    WindowsRouteManager? windowsRouteManager,
    VpnCoreProcessStarter? processStarter,
    VpnCoreProcessRunner? processRunner,
    bool? isWindowsOverride,
    bool? isAndroidOverride,
  }) : _isWindowsOverride = isWindowsOverride,
       _isAndroidOverride = isAndroidOverride {
    _processStarter = processStarter ?? _defaultProcessStarter;
    _processRunner = processRunner ?? _defaultProcessRunner;
    _wintunManager = wintunManager ?? WintunManager();
    _tunGuard =
        tunGuard ??
        WindowsTunGuard(
          processRunner: _processRunner,
          processLaunchRecorder: _recordProcessLaunch,
        );
    _binaryManager = binaryManager ?? VpnCoreBinaryManager();
    _androidController = androidController ?? AndroidVpnController();
    _windowsCoreAdapter = windowsCoreAdapter ?? WindowsXrayCoreAdapter();
    _windowsRouteManager =
        windowsRouteManager ??
        WindowsRouteManager(
          processRunner: _processRunner,
          processLaunchRecorder: _recordProcessLaunch,
        );
  }

  late final WintunManager _wintunManager;
  late final WindowsTunGuard _tunGuard;
  late final VpnCoreBinaryManager _binaryManager;
  late final AndroidVpnController _androidController;
  late final WindowsVpnCoreAdapter _windowsCoreAdapter;
  late final WindowsRouteManager _windowsRouteManager;
  late final VpnCoreProcessStarter _processStarter;
  late final VpnCoreProcessRunner _processRunner;
  final bool? _isWindowsOverride;
  final bool? _isAndroidOverride;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _androidConnected = false;
  bool _windowsConnected = false;
  bool _accessDeniedDetected = false;
  bool _startupCheckInProgress = false;
  Timer? _androidNativeLogPollTimer;
  int _lastAndroidNativeDebugLogLength = 0;
  Timer? _trafficPollTimer;
  bool _trafficPollInProgress = false;
  TrafficSamplingMode _trafficSamplingMode = TrafficSamplingMode.stopped;
  final StreamController<int> _trafficController =
      StreamController<int>.broadcast();
  final StreamController<TrafficSample> _trafficSampleController =
      StreamController<TrafficSample>.broadcast();
  int? _lastTrafficUplinkCounter;
  int? _lastTrafficDownlinkCounter;
  String? _lastTrafficCounterSource;

  String? _activeInterfaceName;
  File? _configFile;
  String? _generatedConfig;
  VlessLink? _parsedLink;
  String? _lastStartError;
  final List<String> _recentLogs = <String>[];
  final List<String> _memoryConnectionLogLines = <String>[];
  File? _connectionLogFile;
  final List<String> _pendingConnectionLogLines = <String>[];
  Timer? _connectionLogFlushTimer;
  bool _connectionLogFlushInProgress = false;
  bool _connectionLogDiskEnabled = false;
  bool _developerModeEnabled = false;
  String? _verifiedWindowsBinaryPath;
  String? _verifiedWindowsBinarySignature;
  int _droppedConnectionLogLines = 0;
  bool _connectionLogThrottleMarkerQueued = false;
  // Every start/stop invalidates older async work. This prevents a late
  // startup callback from reviving a session that the user has cancelled.
  int _connectionOperationEpoch = 0;
  int _sessionEpoch = 0;
  int? _activeConnectionToken;
  final Map<int, String> _sessionInterfaces = <int, String>{};
  final Set<int> _cleanupInProgressTokens = <int>{};
  String _activeWindowsOutboundTag = 'proxy';
  String _activeWindowsInboundTag = WindowsTunGuard.defaultInboundTag;
  String? _lastWindowsRuleHash;
  WindowsRouteSession? _activeWindowsRouteSession;
  final Map<int, WindowsRouteSession> _sessionRoutePlans =
      <int, WindowsRouteSession>{};
  WindowsRouteUplink? _cachedWindowsUplink;
  String? _cachedWindowsExecutablePath;
  Future<void>? _windowsPrewarmFuture;
  bool _windowsRuntimePrepared = false;
  bool _pendingAggressiveRecovery = false;
  final _WindowsRuntimeSessionStore _sessionStore =
      const _WindowsRuntimeSessionStore();
  final Map<String, int> _lastConnectPhaseDurationsMs = <String, int>{};
  final Map<String, int> _lastConnectProcessLaunchCounts = <String, int>{};
  static const int _maxWindowsAutoRecoverAttempts = 3;
  static const int _connectionLogFlushMs = 200;
  static const int _maxPendingConnectionLogLines = 1000;
  static const int _maxMemoryConnectionLogLines = 400;
  static const Duration _windowsPrewarmConnectWaitBudget = Duration(
    milliseconds: 200,
  );
  static const Duration _trafficForegroundPollInterval = Duration(
    milliseconds: 750,
  );
  static const Duration _trafficBackgroundPollInterval = Duration(seconds: 2);

  void Function(String status)? _statusSink;
  void Function(String log)? _logSink;

  VlessLink? get parsedLink => _parsedLink;
  File? get configFile => _configFile;
  String? get generatedConfig => _generatedConfig;
  int get clashApiPort => _windowsCoreAdapter.apiPort;
  Stream<int> get trafficStream => _trafficController.stream;
  Stream<TrafficSample> get trafficSampleStream =>
      _trafficSampleController.stream;
  @visibleForTesting
  Map<String, int> get debugProcessLaunchCounts =>
      Map<String, int>.unmodifiable(_lastConnectProcessLaunchCounts);
  @visibleForTesting
  Map<String, int> get debugConnectPhaseDurationsMs =>
      Map<String, int>.unmodifiable(_lastConnectPhaseDurationsMs);
  @visibleForTesting
  int? get debugActiveConnectionToken => _activeConnectionToken;

  String get interfaceLabel {
    if (_isWindows) {
      return _activeInterfaceName ?? WindowsTunGuard.defaultInterfaceName;
    }
    return 'Android VPN';
  }

  bool get isRunning => _isAndroid ? _androidConnected : _windowsConnected;

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

  Future<String> getAndroidNativeDebugLog() async {
    if (!_isAndroid) return '';
    return _androidController.getNativeDebugLog(runtime: _androidRuntimeId);
  }

  Future<void> clearAndroidNativeDebugLog() async {
    if (!_isAndroid) return;
    _lastAndroidNativeDebugLogLength = 0;
    await _androidController.clearNativeDebugLog(runtime: _androidRuntimeId);
  }

  /// Asks the VPN service to re-register its underlying network callback.
  Future<void> refreshAndroidNetwork() async {
    if (!_isAndroid) return;
    await _androidController.refreshNetwork();
  }

  void _startAndroidNativeLogPolling() {
    if (!_isAndroid || !_useAndroidXrayRuntime) return;
    _androidNativeLogPollTimer?.cancel();
    _androidNativeLogPollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) {
        unawaited(_drainAndroidNativeDebugLog());
      },
    );
    unawaited(_drainAndroidNativeDebugLog());
  }

  Future<void> _stopAndroidNativeLogPolling({bool drain = false}) async {
    _androidNativeLogPollTimer?.cancel();
    _androidNativeLogPollTimer = null;
    if (drain) {
      await _drainAndroidNativeDebugLog();
    }
  }

  Future<void> _drainAndroidNativeDebugLog() async {
    if (!_isAndroid || !_useAndroidXrayRuntime) return;
    try {
      final fullLog = await getAndroidNativeDebugLog();
      if (fullLog.isEmpty) {
        return;
      }
      if (_lastAndroidNativeDebugLogLength > fullLog.length) {
        _lastAndroidNativeDebugLogLength = 0;
      }
      final delta = fullLog.substring(_lastAndroidNativeDebugLogLength);
      _lastAndroidNativeDebugLogLength = fullLog.length;
      final lines = delta
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (lines.isEmpty) {
        return;
      }
      for (final line in lines) {
        _rememberLogLine(line, isError: false);
        _logSink?.call(line);
        _appendConnectionLog(line);
      }
    } catch (_) {
      // Ignore Android native debug log polling failures.
    }
  }

  bool get _isWindows => _isWindowsOverride ?? Platform.isWindows;
  bool get _isAndroid => _isAndroidOverride ?? Platform.isAndroid;
  bool get _useAndroidXrayRuntime => _isAndroid && _androidXrayExperimental;
  String get _androidRuntimeId => 'xray';

  Future<void> prepareWindowsRuntime({
    void Function(String log)? onLog,
    bool force = false,
  }) async {
    if (!_isWindows) return;
    if (_windowsRuntimePrepared && !force) {
      unawaited(_startWindowsRuntimePrewarm(onLog: onLog));
      return;
    }
    _windowsRuntimePrepared = true;
    final state = await _sessionStore.read();
    if (!state.dirty) {
      unawaited(_startWindowsRuntimePrewarm(onLog: onLog));
      return;
    }

    final logs = <String>[
      '[recovery] Dirty Windows VPN session marker detected.',
    ];
    _pendingAggressiveRecovery = true;
    try {
      var cleanupSucceeded = true;
      await _terminateExistingProcesses();
      final staleRoutesCleaned = await _windowsRouteManager.cleanupStale(
        ownedInterfaceName: state.interfaceName,
        logs: logs,
      );
      if (!staleRoutesCleaned) {
        logs.add('[recovery] Unable to verify stale route cleanup.');
        cleanupSucceeded = false;
      }
      final knownInterface = state.interfaceName;
      if (knownInterface != null && knownInterface.startsWith('tun-in-')) {
        final tunCleanup = await _tunGuard.cleanupAdapter(knownInterface);
        logs.addAll(tunCleanup.logs);
        if (!tunCleanup.success) {
          logs.add('[recovery] Managed TUN adapter remains: $knownInterface');
          cleanupSucceeded = false;
        }
      } else if (knownInterface != null) {
        logs.add(
          '[recovery] Skipping adapter deletion for runtime interface '
          '$knownInterface; Xray owns its lifecycle.',
        );
      }
      if (cleanupSucceeded) {
        await _sessionStore.clear();
        _pendingAggressiveRecovery = false;
        logs.add('[recovery] Previous Windows VPN session cleanup completed.');
      }
    } catch (e) {
      logs.add('[recovery] Cleanup exception: $e');
    }

    for (final line in logs) {
      onLog?.call(line);
      _logSink?.call(line);
      _appendConnectionLog(line);
    }
    unawaited(_startWindowsRuntimePrewarm(onLog: onLog));
  }

  Future<void> _startWindowsRuntimePrewarm({void Function(String log)? onLog}) {
    if (!_isWindows) return Future<void>.value();
    final existing = _windowsPrewarmFuture;
    if (existing != null) {
      return existing;
    }

    late final Future<void> tracked;
    tracked = _prewarmWindowsRuntime(onLog: onLog).whenComplete(() {
      if (identical(_windowsPrewarmFuture, tracked)) {
        _windowsPrewarmFuture = null;
      }
    });
    _windowsPrewarmFuture = tracked;
    return tracked;
  }

  Future<void> _prewarmWindowsRuntime({
    void Function(String log)? onLog,
  }) async {
    await Future.wait(<Future<void>>[
      _prewarmWindowsCoreBinary(onLog: onLog),
      _prewarmWindowsUplink(onLog: onLog),
      _prewarmWindowsElevation(onLog: onLog),
    ]);
  }

  Future<void> _prewarmWindowsCoreBinary({
    void Function(String log)? onLog,
  }) async {
    try {
      final exePath = await _binaryManager.resolveExecutable(
        androidRuntime: _useAndroidXrayRuntime ? _androidRuntimeId : null,
      );
      if (exePath == null) {
        return;
      }
      final sanityError = await _verifyWindowsCoreBinary(
        exePath,
        recordDiagnostics: false,
      );
      if (sanityError == null) {
        _cachedWindowsExecutablePath = exePath;
      }
    } catch (e) {
      onLog?.call('[prewarm] Windows core warmup failed: $e');
    }
  }

  Future<void> _prewarmWindowsUplink({void Function(String log)? onLog}) async {
    if (_cachedWindowsUplink != null) {
      return;
    }
    try {
      final logs = <String>[];
      final uplink = await _windowsRouteManager.discoverPrimaryUplink(
        logs: logs,
      );
      if (uplink != null) {
        _cachedWindowsUplink = uplink;
      }
    } catch (e) {
      onLog?.call('[prewarm] Windows uplink warmup failed: $e');
    }
  }

  Future<void> _prewarmWindowsElevation({
    void Function(String log)? onLog,
  }) async {
    try {
      await _tunGuard.warmupElevationCheck();
    } catch (e) {
      onLog?.call('[prewarm] Windows elevation warmup failed: $e');
    }
  }

  Future<void> _awaitWindowsPrewarmBudget() async {
    final prewarm = _windowsPrewarmFuture;
    if (prewarm == null) {
      return;
    }
    try {
      await prewarm.timeout(_windowsPrewarmConnectWaitBudget);
    } on TimeoutException {
      _appendConnectionLog('[prewarm] still running; continuing connect path');
    } catch (_) {
      // Warmup is best-effort; the foreground connection path will retry.
    }
  }

  Future<void> setTrafficSamplingMode(TrafficSamplingMode mode) async {
    if (!_isWindows) return;
    if (mode == TrafficSamplingMode.stopped) {
      await stopTrafficStream();
      return;
    }
    _trafficSamplingMode = mode;
    if (_process == null || !_windowsConnected) {
      return;
    }
    await _restartTrafficPollingTimer();
  }

  Future<VpnCoreStartResult> connect({
    required String rawUri,
    required SplitTunnelConfig splitConfig,
    bool developerMode = false,
    SmartRouteEngine? smartRouteEngine,
    DpiEvasionConfig dpiEvasionConfig = DpiEvasionConfig.balanced,
    void Function(String status)? onStatus,
    void Function(String log)? onLog,
  }) async {
    final connectionOperation = ++_connectionOperationEpoch;
    _statusSink = onStatus;
    _logSink = onLog;
    _developerModeEnabled = developerMode;
    _accessDeniedDetected = false;
    _windowsConnected = false;
    _lastStartError = null;
    _recentLogs.clear();
    _resetConnectionLogging(enableDiskLogging: developerMode);
    if (developerMode) {
      await _createConnectionLogFile();
    }
    _beginConnectDiagnostics();

    final trimmed = rawUri.trim();
    if (trimmed.isEmpty) {
      return VpnCoreStartResult.failure('Ошибка: пустой VLESS URI');
    }

    final parsed = parseVlessUri(trimmed);
    if (parsed == null) {
      return VpnCoreStartResult.failure('Ошибка: неверный формат VLESS URI');
    }
    if (!isSecureVlessLink(parsed)) {
      return VpnCoreStartResult.failure(
        'Небезопасный профиль: поддерживаются только TLS/Reality',
      );
    }
    final transportError = validateVlessTransportForXray(parsed);
    if (transportError != null) {
      return VpnCoreStartResult.failure(transportError);
    }
    _parsedLink = parsed;
    _activeWindowsOutboundTag = parsed.tag ?? 'proxy';
    if (!_isWindows && !_isAndroid) {
      return VpnCoreStartResult.failure('Платформа не поддерживается');
    }

    if (_isWindows) {
      await prepareWindowsRuntime(onLog: onLog);
      if (!_isConnectionOperationCurrent(connectionOperation)) {
        return _cancelledConnectResult();
      }
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
      await _ensureSmartRouteWhitelistLoaded(smartRouteEngine, onLog: onLog);
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
      await clearAndroidNativeDebugLog();
      _startAndroidNativeLogPolling();
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
      // Log generated config for debugging (first 1000 chars)
      _appendConnectionLog(
        '[android] generated xray config (${jsonConfig.length} chars): '
        '${jsonConfig.length > 1000 ? '${jsonConfig.substring(0, 1000)}...' : jsonConfig}',
      );
      _notifyStatus('Запрос разрешения VPN');
      bool granted;
      try {
        granted = await _androidController.prepareVpn();
      } catch (e) {
        return VpnCoreStartResult.failure(
          'Не удалось запросить разрешение VPN: $e',
        );
      }
      if (!granted) {
        return VpnCoreStartResult.failure('Разрешение отклонено пользователем');
      }

      final includePackages = splitConfig.mode == 'whitelist'
          ? androidPackages
          : <String>[];
      final excludePackages = splitConfig.mode == 'blacklist'
          ? androidPackages
          : <String>[];

      String? androidExecutablePath;
      if (_useAndroidXrayRuntime) {
        _notifyStatus('Поиск Android xray-core');
        androidExecutablePath = await _binaryManager.resolveExecutable(
          androidRuntime: 'xray',
        );
        if (androidExecutablePath == null) {
          return VpnCoreStartResult.failure(
            'Не найден Android xray-core binary. Добавьте Android Xray runtime в assets/bin.',
          );
        }
      }

      _notifyStatus('Запуск Android Xray сервиса');
      try {
        await _androidController.startVpn(
          jsonConfig,
          runtime: _androidRuntimeId,
          executablePath: androidExecutablePath,
          includePackages: includePackages.isEmpty ? null : includePackages,
          excludePackages: excludePackages.isEmpty ? null : excludePackages,
        );
      } catch (e) {
        return VpnCoreStartResult.failure(
          'Не удалось запустить Android VPN сервис: $e',
        );
      }
      // Snapshot the current last-error BEFORE waiting.  A previous stop
      // writes "stopped by request" which must not be mistaken for a new
      // startup failure.
      final preStartError = await _androidController.getLastStartupError();
      final startup = await _waitForAndroidServiceStartup(
        ignoreError: preStartError,
      );
      _androidConnected = startup.running;
      if (!startup.running) {
        final nativeLog = await getAndroidNativeDebugLog();
        if (nativeLog.isNotEmpty) {
          _emitLogs(nativeLog.split(RegExp(r'[\r\n]+')));
        }
        await _stopAndroidNativeLogPolling();
        final errorDetail = startup.error;
        if (errorDetail != null && errorDetail.isNotEmpty) {
          return VpnCoreStartResult.failure(
            'Android VPN сервис не запустился: $errorDetail',
          );
        }
        return VpnCoreStartResult.failure(
          'Android VPN сервис не запустился (проверьте совместимость конфигурации)',
        );
      }
      _notifyStatus('Android Xray сервис запущен');
      unawaited(_warmupConnection());
      return VpnCoreStartResult.success();
    }

    final result = await _connectWindowsWithAutoRecover(
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
      connectionOperation: connectionOperation,
    );
    if (!result.success) {
      await _captureFailureDiagnostics(
        result.errorMessage ?? 'Windows VPN startup failed',
      );
    } else {
      _emitConnectDiagnosticsIfNeeded(success: true);
    }
    return result;
  }

  Future<VpnCoreStartResult> _connectWindowsWithAutoRecover({
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
    required int connectionOperation,
  }) async {
    await _awaitWindowsPrewarmBudget();
    if (!_isConnectionOperationCurrent(connectionOperation)) {
      return _cancelledConnectResult();
    }
    _notifyStatus('Поиск xray-core');
    var exePath = _cachedWindowsExecutablePath;
    if (exePath != null && !File(exePath).existsSync()) {
      exePath = null;
      _cachedWindowsExecutablePath = null;
    }
    if (exePath == null) {
      exePath = await _measureConnectPhase(
        'binary_resolve',
        () => _binaryManager.resolveExecutable(
          androidRuntime: _useAndroidXrayRuntime ? 'xray' : null,
        ),
      );
      if (exePath != null) {
        _cachedWindowsExecutablePath = exePath;
      }
    } else {
      _lastConnectPhaseDurationsMs['binary_resolve'] = 0;
      _appendConnectionLog('[prewarm] reusing verified xray binary');
    }
    if (exePath == null) {
      return VpnCoreStartResult.failure('Не найден исполняемый файл xray-core');
    }
    final resolvedExePath = exePath;
    final sanityError = await _measureConnectPhase(
      'binary_verify',
      () => _verifyWindowsCoreBinary(resolvedExePath),
    );
    if (!_isConnectionOperationCurrent(connectionOperation)) {
      return _cancelledConnectResult();
    }
    if (sanityError != null) {
      return VpnCoreStartResult.failure(sanityError);
    }

    if (_activeConnectionToken != null) {
      await _cleanupSessionToken(
        _activeConnectionToken!,
        reason: 'pre-connect',
      );
    }
    if (_isWindows) {
      final process = _process;
      if (process != null) {
        await _forceStopProcess(process);
        await _teardownProcess();
      }
    }
    final environment = Map<String, String>.from(Platform.environment);
    String? lastError;

    for (
      var attempt = 1;
      attempt <= _maxWindowsAutoRecoverAttempts;
      attempt++
    ) {
      if (!_isConnectionOperationCurrent(connectionOperation)) {
        return _cancelledConnectResult();
      }
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

      final plan = await _measureConnectPhase(
        'tun_prepare',
        () => _tunGuard.prepare(
          detectExistingAdapters: _pendingAggressiveRecovery,
        ),
      );
      _emitLogs(plan.logs);
      if (!_isConnectionOperationCurrent(connectionOperation)) {
        return _cancelWindowsAttempt(token);
      }
      if (!plan.success) {
        await _cleanupSessionToken(token, reason: 'prepare-failed');
        final message = plan.requiresElevation
            ? '❌ Нужны права администратора для управления TUN интерфейсом'
            : (plan.error ?? 'Не удалось подготовить TUN интерфейс');
        return VpnCoreStartResult.failure(
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
          return VpnCoreStartResult.failure(lastError);
        }
      }

      _activeInterfaceName = plan.interfaceName;
      _activeWindowsInboundTag = plan.inboundTag;
      _sessionInterfaces[token] = plan.interfaceName;
      await _sessionStore.markDirty(
        interfaceName: plan.interfaceName,
        remoteHost: parsed.host,
      );
      // A prewarm result is advisory only. The physical route may change
      // between app launch and the moment we redirect the default route.
      final uplinkDiscoveryLogs = <String>[];
      final uplink = await _measureConnectPhase(
        'uplink_discovery',
        () => _windowsRouteManager.discoverPrimaryUplink(
          logs: uplinkDiscoveryLogs,
        ),
      );
      _emitLogs(uplinkDiscoveryLogs);
      if (!_isConnectionOperationCurrent(connectionOperation)) {
        return _cancelWindowsAttempt(token);
      }
      if (uplink == null) {
        lastError = 'Не удалось определить активный uplink Windows';
        await _cleanupSessionToken(token, reason: 'uplink-discovery-failed');
        if (attempt >= _maxWindowsAutoRecoverAttempts) {
          return VpnCoreStartResult.failure(lastError);
        }
        _notifyStatus(
          'Автовосстановление... попытка ${attempt + 1}/$_maxWindowsAutoRecoverAttempts',
        );
        continue;
      }
      final endpoint = await _measureConnectPhase(
        'endpoint_resolve',
        () => _resolveWindowsEndpoint(parsed.host),
      );
      if (!_isConnectionOperationCurrent(connectionOperation)) {
        return _cancelWindowsAttempt(token);
      }
      if (endpoint.serverAddressOverride != null) {
        _appendConnectionLog(
          '[token=$token] using resolved server IP '
          '${endpoint.serverAddressOverride} for ${parsed.host}',
        );
      }
      _notifyStatus('Генерация конфига');
      final jsonConfig = _buildConfigJson(
        parsed: parsed,
        splitConfig: splitConfig,
        inboundTag: plan.inboundTag,
        interfaceName: plan.interfaceName,
        interfaceAddresses: plan.addresses,
        outboundInterfaceName: uplink.interfaceName,
        outboundBindAddress: uplink.localAddress,
        useSmartEngineRules: useSmartEngineRules,
        extraRouteRules: extraRouteRules,
        extraOutbounds: extraOutbounds,
        extraInbounds: extraInbounds,
        dnsServers: dnsServers,
        dnsFinalTag: dnsFinalTag,
        dpiEvasionConfig: dpiEvasionConfig,
        developerMode: developerMode,
        serverAddressOverride: endpoint.serverAddressOverride,
      );
      _generatedConfig = jsonConfig;

      final tempDir = await _measureConnectPhase(
        'config_tempdir',
        () => Directory.systemTemp.createTemp('xray_cfg_'),
      );
      final cfgFile = File('${tempDir.path}/config.json');
      await _measureConnectPhase(
        'config_write',
        () => cfgFile.writeAsString(jsonConfig),
      );
      _configFile = cfgFile;
      if (!_isConnectionOperationCurrent(connectionOperation)) {
        return _cancelWindowsAttempt(token);
      }

      _notifyStatus('Проверка конфигурации');
      final configValidationError = await _measureConnectPhase(
        'config_validate',
        () => _validateWindowsConfig(resolvedExePath, cfgFile),
      );
      if (!_isConnectionOperationCurrent(connectionOperation)) {
        return _cancelWindowsAttempt(token);
      }
      if (configValidationError != null) {
        await _cleanupSessionToken(token, reason: 'config-validation-failed');
        return VpnCoreStartResult.failure(configValidationError);
      }

      _notifyStatus('Запуск процесса');
      _appendConnectionLog(
        '[token=$token] auto-recover attempt started '
        'with interface=${plan.interfaceName}',
      );
      try {
        final process = await _measureConnectPhase(
          'process_start',
          () => _startMeasuredProcess(resolvedExePath, [
            'run',
            '-c',
            cfgFile.path,
          ], environment: environment),
        );
        _process = process;
        _attachProcessHandlers(process, token);
        await _sessionStore.markDirty(
          interfaceName: plan.interfaceName,
          remoteHost: parsed.host,
          pid: process.pid,
        );
        if (!_isConnectionOperationCurrent(connectionOperation)) {
          return _cancelWindowsAttempt(token, process: process);
        }
        final startupError = await _measureConnectPhase(
          'startup_verify',
          () => _verifyStartup(process, plan.interfaceName),
        );
        if (!_isConnectionOperationCurrent(connectionOperation)) {
          return _cancelWindowsAttempt(token, process: process);
        }
        if (startupError == null) {
          final routeResult = await _measureConnectPhase(
            'route_apply',
            () => _windowsRouteManager.applyRoutes(
              preferredTunInterface: _activeInterfaceName ?? plan.interfaceName,
              remoteHost: endpoint.routeHost,
              dnsServers: const <String>['8.8.8.8', '1.1.1.1'],
              tunAddressHint: plan.addresses.isEmpty
                  ? null
                  : plan.addresses.first,
              uplink: uplink,
            ),
          );
          _emitLogs(routeResult.logs);
          if (!_isConnectionOperationCurrent(connectionOperation)) {
            return _cancelWindowsAttempt(token, process: process);
          }
          if (!routeResult.success || routeResult.session == null) {
            final routeError =
                routeResult.error ??
                'Не удалось перенаправить Windows трафик в TUN';
            _appendConnectionLog(
              '[token=$token] route setup failed: $routeError',
            );
            await _forceStopProcess(process);
            await _teardownProcess();
            _cachedWindowsUplink = null;
            await _cleanupSessionToken(token, reason: 'route-setup-failed');
            if (attempt >= _maxWindowsAutoRecoverAttempts) {
              return VpnCoreStartResult.failure(routeError);
            }
            _notifyStatus(
              'Автовосстановление... попытка ${attempt + 1}/$_maxWindowsAutoRecoverAttempts',
            );
            continue;
          }
          _activeWindowsRouteSession = routeResult.session;
          _sessionRoutePlans[token] = routeResult.session!;
          // Xray can choose a runtime adapter name (usually xray0) that is
          // different from the requested session name. Keep the runtime name
          // for cleanup and adapter statistics, while retaining inboundTag.
          _activeInterfaceName = routeResult.session!.tunInterfaceName;
          _sessionInterfaces[token] = routeResult.session!.tunInterfaceName;
          await _sessionStore.markDirty(
            interfaceName: routeResult.session!.tunInterfaceName,
            remoteHost: parsed.host,
            pid: process.pid,
          );
          _cachedWindowsUplink = uplink;
          _pendingAggressiveRecovery = false;
          _windowsConnected = true;
          _notifyStatus(
            'Подключено (TUN: ${routeResult.session!.tunInterfaceName})',
          );
          _lastWindowsRuleHash = _computeWindowsRuleHash(jsonConfig);
          _appendConnectionLog(
            '[token=$token] auto-recover attempt succeeded '
            'interface=${routeResult.session!.tunInterfaceName}',
          );
          unawaited(_warmupConnection());
          return VpnCoreStartResult.success();
        }

        lastError = startupError;
        final failureClass = _classifyStartupFailure(startupError);
        _appendConnectionLog(
          '[token=$token] auto-recover attempt failed '
          'class=${failureClass.name} error=$startupError',
        );

        await _forceStopProcess(process);
        await _teardownProcess();
        _cachedWindowsUplink = null;
        await _cleanupSessionToken(token, reason: 'startup-failed');

        if (failureClass == _StartupFailureClass.requiresAdmin ||
            _accessDeniedDetected) {
          return VpnCoreStartResult.failure(startupError, requiresAdmin: true);
        }

        if (failureClass == _StartupFailureClass.fatal ||
            attempt >= _maxWindowsAutoRecoverAttempts) {
          return VpnCoreStartResult.failure(startupError);
        }

        _notifyStatus(
          'Автовосстановление... попытка ${attempt + 1}/$_maxWindowsAutoRecoverAttempts',
        );
      } catch (e) {
        lastError = 'Ошибка запуска: $e';
        _appendConnectionLog('[token=$token] process start exception: $e');
        await _teardownProcess();
        _cachedWindowsUplink = null;
        await _cleanupSessionToken(token, reason: 'process-start-exception');
        if (attempt >= _maxWindowsAutoRecoverAttempts) {
          return VpnCoreStartResult.failure(lastError);
        }
      }
    }

    return VpnCoreStartResult.failure(
      lastError ?? 'Ошибка запуска: неизвестная ошибка',
    );
  }

  bool _isConnectionOperationCurrent(int operation) =>
      operation == _connectionOperationEpoch;

  VpnCoreStartResult _cancelledConnectResult() =>
      VpnCoreStartResult.failure('Подключение отменено');

  Future<VpnCoreStartResult> _cancelWindowsAttempt(
    int token, {
    Process? process,
  }) async {
    if (process != null && identical(_process, process)) {
      await _forceStopProcess(process);
      await _teardownProcess();
    }
    await _cleanupSessionToken(token, reason: 'connect-cancelled');
    return _cancelledConnectResult();
  }

  bool _isManagedTunPlanName(String name) => name.startsWith('tun-in-');

  String _buildConfigJson({
    required VlessLink parsed,
    required SplitTunnelConfig splitConfig,
    required String inboundTag,
    required String interfaceName,
    required List<String> interfaceAddresses,
    String? outboundInterfaceName,
    String? outboundBindAddress,
    required bool useSmartEngineRules,
    required List<Map<String, dynamic>> extraRouteRules,
    required List<Map<String, dynamic>> extraOutbounds,
    required List<Map<String, dynamic>> extraInbounds,
    required List<Map<String, dynamic>>? dnsServers,
    required String? dnsFinalTag,
    required DpiEvasionConfig dpiEvasionConfig,
    required bool developerMode,
    String? serverAddressOverride,
  }) {
    if (_isWindows) {
      return _windowsCoreAdapter.generateConfig(
        parsed: parsed,
        splitConfig: splitConfig,
        inboundTag: inboundTag,
        interfaceName: interfaceName,
        interfaceAddresses: interfaceAddresses,
        outboundInterfaceName: outboundInterfaceName,
        outboundBindAddress: outboundBindAddress,
        extraRouteRules: extraRouteRules,
        dpiEvasionConfig: dpiEvasionConfig,
        developerMode: developerMode,
        serverAddressOverride: serverAddressOverride,
      );
    }
    if (_useAndroidXrayRuntime) {
      return generateAndroidXrayConfig(
        parsed,
        splitConfig,
        inboundTag: inboundTag,
        smartRouting: splitConfig.smartRouting && !useSmartEngineRules,
        smartDomains: splitConfig.smartRouting && !useSmartEngineRules
            ? splitConfig.smartDomains
            : const <String>[],
        extraRouteRules: extraRouteRules,
        logLevel: developerMode ? 'debug' : 'info',
      );
    }
    return generateSingBoxConfig(
      parsed,
      splitConfig,
      inboundTag: inboundTag,
      interfaceName: interfaceName,
      addresses: interfaceAddresses,
      tunStack: tunStackFromPlatform,
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
      clashApiPort: _isWindows ? _xrayApiPort : null,
      logLevel: developerMode ? 'debug' : 'info',
    );
  }

  String get tunStackFromPlatform => _isAndroid ? 'gvisor' : 'system';
  int get _xrayApiPort => _windowsCoreAdapter.apiPort;

  Future<({bool running, String? error})> _waitForAndroidServiceStartup({
    String? ignoreError,
  }) async {
    if (!_isAndroid) return (running: true, error: null);
    // The service runs in a separate process. Give it enough time to
    // bootstrap libXray, start the Xray core, establish TUN, and launch
    // tun2socks. 20 × 300ms = 6 seconds — enough for cold-start.
    const attempts = 20;
    for (var i = 0; i < attempts; i++) {
      // Check for a startup error first — the service writes it BEFORE
      // calling stopSelf(), so it may appear before isRunning flips.
      // Ignore a stale error left over from a previous stop cycle.
      final error = await _androidController.getLastStartupError();
      if (error != null && error.isNotEmpty && error != ignoreError) {
        return (running: false, error: error);
      }
      final running = await _androidController.isRunning();
      if (running) return (running: true, error: null);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return (running: false, error: null);
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

  Future<_WindowsEndpointResolution> _resolveWindowsEndpoint(
    String host,
  ) async {
    final trimmed = host.trim();
    if (trimmed.isEmpty || _looksLikeIpv4(trimmed)) {
      return _WindowsEndpointResolution(routeHost: trimmed);
    }

    try {
      final resolved = await InternetAddress.lookup(
        trimmed,
      ).timeout(const Duration(milliseconds: 1000));
      final ipv4 = resolved
          .where((address) => address.type == InternetAddressType.IPv4)
          .map((address) => address.address)
          .where(_looksLikeIpv4)
          .toList();
      if (ipv4.isEmpty) {
        _appendConnectionLog('[endpoint] no IPv4 result for $trimmed');
        return _WindowsEndpointResolution(routeHost: trimmed);
      }
      return _WindowsEndpointResolution(
        routeHost: ipv4.first,
        serverAddressOverride: ipv4.first,
      );
    } on TimeoutException {
      _appendConnectionLog('[endpoint] resolve timed out for $trimmed');
    } catch (e) {
      _appendConnectionLog('[endpoint] resolve failed for $trimmed: $e');
    }
    return _WindowsEndpointResolution(routeHost: trimmed);
  }

  bool _looksLikeIpv4(String value) {
    return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(value);
  }

  Future<String?> _verifyWindowsCoreBinary(
    String executablePath, {
    bool recordDiagnostics = true,
  }) async {
    if (!_isWindows) return null;
    if (_verifiedWindowsBinaryPath == executablePath &&
        _verifiedWindowsBinarySignature == _windowsCoreAdapter.processName) {
      return null;
    }
    try {
      final result = recordDiagnostics
          ? await _runMeasuredProcess(executablePath, const ['version'])
          : await _processRunner(executablePath, const ['version']);
      if (result.exitCode != 0) {
        return 'xray-core не отвечает: code ${result.exitCode}';
      }
      final output =
          '${result.stdout}'.toLowerCase() + '\n${result.stderr}'.toLowerCase();
      final expected = _windowsCoreAdapter.processName.replaceAll('.exe', '');
      if (!output.contains(expected)) {
        return 'Неверный Windows core binary: ожидается xray-core';
      }
      _verifiedWindowsBinaryPath = executablePath;
      _verifiedWindowsBinarySignature = _windowsCoreAdapter.processName;
      return null;
    } catch (e) {
      return 'Не удалось проверить xray-core binary: $e';
    }
  }

  Future<String?> _validateWindowsConfig(
    String executablePath,
    File configFile,
  ) async {
    try {
      final result = await _runMeasuredProcess(executablePath, [
        'run',
        '-test',
        '-c',
        configFile.path,
      ]);
      if (result.exitCode == 0) return null;
      final details = '${result.stderr}\n${result.stdout}'.trim();
      final compact = details.replaceAll(RegExp(r'\s+'), ' ');
      return compact.isEmpty
          ? 'Конфигурация Xray не прошла проверку'
          : 'Конфигурация Xray не прошла проверку: $compact';
    } catch (e) {
      return 'Не удалось проверить конфигурацию Xray: $e';
    }
  }

  String? _computeWindowsRuleHash(String jsonConfig) {
    if (!_isWindows) return null;
    return _windowsCoreAdapter.computeRuleHash(jsonConfig);
  }

  Future<void> _ensureSmartRouteWhitelistLoaded(
    SmartRouteEngine smartRouteEngine, {
    void Function(String log)? onLog,
  }) async {
    try {
      final added = await smartRouteEngine.ensureBundledWhitelistLoaded();
      if (added <= 0) return;
      final line =
          '[smart-routing] loaded $added bundled Russian direct domains';
      onLog?.call(line);
      _appendConnectionLog(line);
    } catch (e) {
      final line = '[smart-routing] bundled whitelist load failed: $e';
      onLog?.call(line);
      _appendConnectionLog(line);
    }
  }

  Future<bool> hotReloadWindowsRules({
    required SplitTunnelConfig splitConfig,
    bool developerMode = false,
    SmartRouteEngine? smartRouteEngine,
    DpiEvasionConfig dpiEvasionConfig = DpiEvasionConfig.balanced,
    void Function(String log)? onLog,
  }) async {
    if (!_isWindows || _process == null || _parsedLink == null) {
      return false;
    }

    final extraRouteRules = <Map<String, dynamic>>[];
    final useSmartEngineRules =
        smartRouteEngine != null && splitConfig.smartRouting;
    if (useSmartEngineRules) {
      await _ensureSmartRouteWhitelistLoaded(smartRouteEngine, onLog: onLog);
      extraRouteRules.addAll(
        smartRouteEngine.buildRouteRules(outboundTag: 'direct'),
      );
    }

    final jsonConfig = _buildConfigJson(
      parsed: _parsedLink!,
      splitConfig: splitConfig,
      inboundTag: _activeWindowsInboundTag,
      interfaceName:
          _activeInterfaceName ?? WindowsTunGuard.defaultInterfaceName,
      interfaceAddresses: const ['172.19.0.1/30'],
      outboundInterfaceName: _activeWindowsRouteSession?.uplinkInterfaceName,
      outboundBindAddress: _activeWindowsRouteSession?.uplinkAddress,
      useSmartEngineRules: useSmartEngineRules,
      extraRouteRules: extraRouteRules,
      extraOutbounds: const <Map<String, dynamic>>[],
      extraInbounds: const <Map<String, dynamic>>[],
      dnsServers: null,
      dnsFinalTag: null,
      dpiEvasionConfig: dpiEvasionConfig,
      developerMode: developerMode,
    );
    final nextHash = _computeWindowsRuleHash(jsonConfig);
    if (nextHash != null && nextHash == _lastWindowsRuleHash) {
      return true;
    }

    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(jsonConfig);
      if (decoded is! Map<String, dynamic>) return false;
      final routing = decoded['routing'];
      if (routing is! Map<String, dynamic>) return false;
      payload = routing;
    } catch (_) {
      return false;
    }

    final exePath = await _binaryManager.resolveExecutable();
    if (exePath == null) {
      return false;
    }

    final tempDir = await Directory.systemTemp.createTemp('xray_rules_');
    final routeFile = File('${tempDir.path}/routing.json');
    await routeFile.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(<String, dynamic>{'routing': payload}),
      flush: true,
    );

    final commands = <List<String>>[
      ['api', 'adrules', '--server=127.0.0.1:$_xrayApiPort', routeFile.path],
      ['api', 'adrules', '-s', '127.0.0.1:$_xrayApiPort', routeFile.path],
    ];

    for (final args in commands) {
      try {
        final result = await _runMeasuredProcess(exePath, args);
        if (result.exitCode == 0) {
          _lastWindowsRuleHash = nextHash;
          onLog?.call('[xray] routing hot-reload applied');
          return true;
        }
        final stderr = '${result.stderr}'.trim();
        final stdout = '${result.stdout}'.trim();
        onLog?.call(
          '[xray] adrules failed: '
          '${stderr.isNotEmpty
              ? stderr
              : stdout.isNotEmpty
              ? stdout
              : 'exit=${result.exitCode}'}',
        );
      } catch (e) {
        onLog?.call('[xray] adrules exception: $e');
      }
    }

    return false;
  }

  Future<void> _terminateExistingProcesses() async {
    if (!_isWindows) return;
    final process = _process;
    if (process != null) {
      await _forceStopProcess(process);
      await _teardownProcess();
    }
  }

  Future<void> disconnect({
    void Function(String status)? onStatus,
    void Function(String log)? onLog,
  }) async {
    _connectionOperationEpoch++;
    _statusSink = onStatus ?? _statusSink;
    _logSink = onLog ?? _logSink;

    if (_isAndroid) {
      final running = await syncRuntimeState();
      if (!running) {
        await _stopAndroidNativeLogPolling(drain: true);
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
      await _stopAndroidNativeLogPolling(drain: true);
      if (stopped) {
        _notifyStatus('Остановлено');
      } else {
        _notifyStatus('Android VPN сервис все еще активен');
      }
      return;
    }

    final process = _process;
    _notifyStatus('Остановка...');
    _windowsConnected = false;
    if (process != null) {
      await _forceStopProcess(process);
    }
    await _teardownProcess();

    final activeToken = _activeConnectionToken;
    if (activeToken != null) {
      await _cleanupSessionToken(activeToken, reason: 'manual-disconnect');
    } else if (_activeInterfaceName != null) {
      if (_activeWindowsRouteSession != null) {
        final routeLogs = <String>[];
        await _windowsRouteManager.cleanupSession(
          _activeWindowsRouteSession,
          logs: routeLogs,
        );
        _emitLogs(routeLogs);
        _activeWindowsRouteSession = null;
      }
      if (_isManagedTunPlanName(_activeInterfaceName!)) {
        final cleanup = await _tunGuard.cleanupAdapter(_activeInterfaceName);
        _emitLogs(cleanup.logs);
      }
      _activeInterfaceName = null;
    }
    _cachedWindowsUplink = null;
    await _sessionStore.clear();
    await _flushConnectionLog(force: true);
    _notifyStatus('Остановлено');
  }

  Future<void> forceTerminate() async {
    _connectionOperationEpoch++;
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
            await _stopAndroidNativeLogPolling(drain: true);
            return;
          }
        }
      }
      final stopped = await _waitForAndroidServiceStop();
      _androidConnected = !stopped;
      await _stopAndroidNativeLogPolling(drain: true);
      return;
    }

    if (_isWindows) {
      _windowsConnected = false;
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
      if (_activeWindowsRouteSession != null) {
        final routeLogs = <String>[];
        await _windowsRouteManager.cleanupSession(
          _activeWindowsRouteSession,
          logs: routeLogs,
        );
        _emitLogs(routeLogs);
        _activeWindowsRouteSession = null;
      }
      if (_isManagedTunPlanName(_activeInterfaceName!)) {
        final cleanup = await _tunGuard.cleanupAdapter(_activeInterfaceName);
        _emitLogs(cleanup.logs);
      }
      _activeInterfaceName = null;
    }
    _cachedWindowsUplink = null;
    await _sessionStore.clear();
    await _flushConnectionLog(force: true);
  }

  Future<void> dispose() async {
    await disconnect();
    await _teardownProcess();
    await _sessionStore.clear();
    await _flushConnectionLog(force: true);
  }

  void _attachProcessHandlers(Process process, int token) {
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
      final hint = _latestMeaningfulProcessLog();
      _appendConnectionLog(
        '[token=$token] xray-core exited code=$code'
        '${hint == null ? '' : ' lastLog=$hint'}',
      );
      await _teardownProcess();
      _windowsConnected = false;
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
    _windowsConnected = false;
  }

  Future<TrafficSample?> fetchTrafficSample({bool useDelta = false}) async {
    if (_isAndroid) {
      return _fetchAndroidTrafficSample(useDelta: useDelta);
    }
    if (!_isWindows) return null;
    if (_process == null) return null;
    try {
      int? down;
      int? up;
      String? source;
      String? exePath;

      // 1) Default steady-state source: Windows adapter byte counters.
      final adapterPair = await _fetchAdapterTrafficPair();
      if (adapterPair.$1 != null || adapterPair.$2 != null) {
        down = adapterPair.$1 ?? 0;
        up = adapterPair.$2 ?? 0;
        source = 'adapter-stats';
      }

      // 2) Fallback: exact TUN inbound counters via `api stats`.
      if (down == null && up == null) {
        exePath ??= await _binaryManager.resolveExecutable();
        if (exePath == null) {
          return null;
        }
        final tunPair = await _fetchTrafficPairByStatsApi(
          exePath: exePath,
          downlinkName:
              'inbound>>>$_activeWindowsInboundTag>>>traffic>>>downlink',
          uplinkName: 'inbound>>>$_activeWindowsInboundTag>>>traffic>>>uplink',
        );
        if (tunPair.$1 != null || tunPair.$2 != null) {
          down = tunPair.$1 ?? 0;
          up = tunPair.$2 ?? 0;
          source = 'xray-api-stats-tun';
        }
      }

      // 3) Secondary API source: active outbound counters.
      if (down == null && up == null) {
        exePath ??= await _binaryManager.resolveExecutable();
        if (exePath == null) {
          return null;
        }
        final activePair = await _fetchTrafficPairByStatsApi(
          exePath: exePath,
          downlinkName:
              'outbound>>>$_activeWindowsOutboundTag>>>traffic>>>downlink',
          uplinkName:
              'outbound>>>$_activeWindowsOutboundTag>>>traffic>>>uplink',
        );
        if (activePair.$1 != null || activePair.$2 != null) {
          down = activePair.$1 ?? 0;
          up = activePair.$2 ?? 0;
          source = 'xray-api-stats-outbound';
        }
      }

      // 4) Final compatibility fallback: full statsquery parser.
      if (down == null && up == null) {
        exePath ??= await _binaryManager.resolveExecutable();
        if (exePath == null) {
          return null;
        }
        final result = await _runMeasuredProcess(exePath, [
          'api',
          'statsquery',
          '--server=127.0.0.1:$_xrayApiPort',
        ]);
        if (result.exitCode != 0) {
          return null;
        }
        final payload = '${result.stdout}\n${result.stderr}';
        final counters = _extractXrayTrafficCounters(payload);
        final tunDown =
            counters['inbound>>>$_activeWindowsInboundTag>>>traffic>>>downlink'];
        final tunUp =
            counters['inbound>>>$_activeWindowsInboundTag>>>traffic>>>uplink'];
        final activeDown =
            counters['outbound>>>$_activeWindowsOutboundTag>>>traffic>>>downlink'];
        final activeUp =
            counters['outbound>>>$_activeWindowsOutboundTag>>>traffic>>>uplink'];

        if (tunDown != null || tunUp != null) {
          down = tunDown ?? 0;
          up = tunUp ?? 0;
          source = 'xray-statsquery-tun';
        } else {
          down = activeDown;
          up = activeUp;
          source = 'xray-statsquery-active';

          final summedOut = _sumOutboundCounters(counters);
          final summedIn = _sumInboundCounters(counters);
          if (down == null && up == null) {
            down = summedOut.$1;
            up = summedOut.$2;
          } else if ((down ?? 0) == 0 && (up ?? 0) == 0) {
            final sumDown = summedOut.$1 ?? 0;
            final sumUp = summedOut.$2 ?? 0;
            if (sumDown > 0 || sumUp > 0) {
              down = sumDown;
              up = sumUp;
              source = 'xray-statsquery-summed-out';
            } else {
              final inDown = summedIn.$1 ?? 0;
              final inUp = summedIn.$2 ?? 0;
              if (inDown > 0 || inUp > 0) {
                down = inDown;
                up = inUp;
                source = 'xray-statsquery-summed-in';
              }
            }
          }

          if (down == null && up == null) {
            down = summedIn.$1;
            up = summedIn.$2;
            source = 'xray-statsquery-summed-in';
          }
        }
      }

      if (down == null && up == null) {
        return null;
      }
      final currentDown = down ?? 0;
      final currentUp = up ?? 0;
      if (_lastTrafficCounterSource != null &&
          source != null &&
          _lastTrafficCounterSource != source) {
        _lastTrafficDownlinkCounter = null;
        _lastTrafficUplinkCounter = null;
      }
      _lastTrafficCounterSource = source ?? _lastTrafficCounterSource;
      final deltaDown = _computeTrafficDelta(
        current: currentDown,
        previous: _lastTrafficDownlinkCounter,
        useDelta: useDelta,
      );
      final deltaUp = _computeTrafficDelta(
        current: currentUp,
        previous: _lastTrafficUplinkCounter,
        useDelta: useDelta,
      );
      _lastTrafficDownlinkCounter = currentDown;
      _lastTrafficUplinkCounter = currentUp;
      return TrafficSample(uplinkBps: deltaUp, downlinkBps: deltaDown);
    } catch (_) {
      return null;
    }
  }

  Future<TrafficSample?> _fetchAndroidTrafficSample({
    bool useDelta = false,
  }) async {
    if (!_androidConnected) return null;
    try {
      final stats = await _androidController.getTrafficStats();
      if (stats == null) return null;
      // stats.tx = upload (device → network), stats.rx = download (network → device)
      final currentUp = stats.tx;
      final currentDown = stats.rx;
      if (_lastTrafficCounterSource != null &&
          _lastTrafficCounterSource != 'android-tun2socks') {
        _lastTrafficDownlinkCounter = null;
        _lastTrafficUplinkCounter = null;
      }
      _lastTrafficCounterSource = 'android-tun2socks';
      final deltaDown = _computeTrafficDelta(
        current: currentDown,
        previous: _lastTrafficDownlinkCounter,
        useDelta: useDelta,
      );
      final deltaUp = _computeTrafficDelta(
        current: currentUp,
        previous: _lastTrafficUplinkCounter,
        useDelta: useDelta,
      );
      _lastTrafficDownlinkCounter = currentDown;
      _lastTrafficUplinkCounter = currentUp;
      return TrafficSample(uplinkBps: deltaUp, downlinkBps: deltaDown);
    } catch (_) {
      return null;
    }
  }

  Future<(int?, int?)> _fetchAdapterTrafficPair() async {
    if (!_isWindows) return (null, null);
    final preferred = _activeWindowsRouteSession?.tunInterfaceName ?? 'xray0';
    final quotedPreferred = preferred.replaceAll("'", "''");
    final script =
        '''
\$preferred = '$quotedPreferred'
\$candidates = @(\$preferred,'xray0','xray0 1') | Select-Object -Unique
foreach (\$name in \$candidates) {
  if (-not \$name) { continue }
  \$s = Get-NetAdapterStatistics -Name \$name -ErrorAction SilentlyContinue
  if (\$s) {
    [pscustomobject]@{
      Name = \$name
      ReceivedBytes = [int64]\$s.ReceivedBytes
      SentBytes = [int64]\$s.SentBytes
    } | ConvertTo-Json -Compress
    exit 0
  }
}
\$adapter = \$null
if (-not \$adapter) {
  \$adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
    Where-Object { \$_.Name -like 'xray*' -or \$_.Name -like 'tun-in*' -or \$_.Name -like 'wintun*' } |
    Sort-Object Name |
    Select-Object -First 1
}
if (-not \$adapter) { exit 0 }
\$s = Get-NetAdapterStatistics -Name \$adapter.Name -ErrorAction SilentlyContinue
if (-not \$s) { exit 0 }
[pscustomobject]@{
  Name = \$adapter.Name
  ReceivedBytes = [int64]\$s.ReceivedBytes
  SentBytes = [int64]\$s.SentBytes
} | ConvertTo-Json -Compress
''';
    try {
      final result = await _runMeasuredProcess('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]);
      if (result.exitCode != 0) return (null, null);
      final raw = '${result.stdout}'.trim();
      if (raw.isEmpty) return (null, null);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return (null, null);
      final down = int.tryParse('${decoded['ReceivedBytes'] ?? ''}');
      final up = int.tryParse('${decoded['SentBytes'] ?? ''}');
      return (down, up);
    } catch (_) {
      return (null, null);
    }
  }

  Future<(int?, int?)> _fetchTrafficPairByStatsApi({
    required String exePath,
    required String downlinkName,
    required String uplinkName,
  }) async {
    final down = await _fetchSingleTrafficStatByName(
      exePath: exePath,
      statName: downlinkName,
    );
    final up = await _fetchSingleTrafficStatByName(
      exePath: exePath,
      statName: uplinkName,
    );
    return (down, up);
  }

  Future<int?> _fetchSingleTrafficStatByName({
    required String exePath,
    required String statName,
  }) async {
    final result = await _runMeasuredProcess(exePath, [
      'api',
      'stats',
      '--server=127.0.0.1:$_xrayApiPort',
      '--name=$statName',
    ]);
    if (result.exitCode != 0) {
      return null;
    }
    final payload = '${result.stdout}\n${result.stderr}';
    final namedValue = _extractXrayStatValue(payload, statName);
    if (namedValue != null) {
      return namedValue;
    }
    final generic = RegExp(
      r'value:\s*"?(\d+)"?',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(payload);
    if (generic != null) {
      return int.tryParse(generic.group(1) ?? '');
    }
    return null;
  }

  int _computeTrafficDelta({
    required int current,
    required int? previous,
    required bool useDelta,
  }) {
    if (!useDelta) return current;
    if (previous == null) {
      return current;
    }
    final diff = current - previous;
    if (diff >= 0) {
      return diff.clamp(0, 1 << 31);
    }
    // Some runtimes/query modes can reset counters between samples.
    // In that case current already represents the latest interval traffic.
    return current.clamp(0, 1 << 31);
  }

  Future<int?> fetchTrafficBps() async {
    final sample = await fetchTrafficSample();
    return sample?.totalBps;
  }

  Future<void> startTrafficStream() async {
    if (!_isWindows && !_isAndroid) return;
    if (_trafficSamplingMode == TrafficSamplingMode.stopped) {
      _trafficSamplingMode = TrafficSamplingMode.foreground;
    }
    if (_trafficPollTimer != null) return;
    _lastTrafficUplinkCounter = null;
    _lastTrafficDownlinkCounter = null;
    _lastTrafficCounterSource = null;
    await _restartTrafficPollingTimer();
  }

  Future<void> stopTrafficStream() async {
    _trafficPollTimer?.cancel();
    _trafficPollTimer = null;
    _trafficPollInProgress = false;
    _trafficSamplingMode = TrafficSamplingMode.stopped;
    _lastTrafficUplinkCounter = null;
    _lastTrafficDownlinkCounter = null;
    _lastTrafficCounterSource = null;
  }

  Future<void> _restartTrafficPollingTimer() async {
    _trafficPollTimer?.cancel();
    final interval = _pollIntervalForTrafficMode(_trafficSamplingMode);
    _trafficPollTimer = Timer.periodic(interval, (_) async {
      if (_trafficPollInProgress) {
        return;
      }
      _trafficPollInProgress = true;
      try {
        final sample = await fetchTrafficSample(useDelta: true);
        if (sample != null) {
          _trafficSampleController.add(sample);
          _trafficController.add(sample.totalBps);
        }
      } finally {
        _trafficPollInProgress = false;
      }
    });
  }

  Duration _pollIntervalForTrafficMode(TrafficSamplingMode mode) {
    switch (mode) {
      case TrafficSamplingMode.foreground:
        return _trafficForegroundPollInterval;
      case TrafficSamplingMode.background:
        return _trafficBackgroundPollInterval;
      case TrafficSamplingMode.stopped:
        return _trafficBackgroundPollInterval;
    }
  }

  int? _extractXrayStatValue(String payload, String statName) {
    final escapedName = RegExp.escape(statName);
    final blockMatch = RegExp(
      'name:\\s*"$escapedName"[\\s\\S]*?value:\\s*(\\d+)',
      multiLine: true,
    ).firstMatch(payload);
    if (blockMatch != null) {
      return int.tryParse(blockMatch.group(1) ?? '');
    }

    final jsonLike = RegExp(
      '"$escapedName"\\s*[:=]\\s*(\\d+)',
      multiLine: true,
    ).firstMatch(payload);
    if (jsonLike != null) {
      return int.tryParse(jsonLike.group(1) ?? '');
    }
    return null;
  }

  Map<String, int> _extractXrayTrafficCounters(String payload) {
    final result = <String, int>{};
    final protoMatches = RegExp(
      r'name:\s*"([^"]+)"\s*value:\s*"?(\d+)"?',
      multiLine: true,
    ).allMatches(payload);
    for (final match in protoMatches) {
      final name = match.group(1);
      final valueRaw = match.group(2);
      final value = int.tryParse(valueRaw ?? '');
      if (name == null || value == null) continue;
      result[name] = value;
    }
    final jsonMatches = RegExp(
      r'"([^"]+)"\s*:\s*"?(\d+)"?',
      multiLine: true,
    ).allMatches(payload);
    for (final match in jsonMatches) {
      final name = match.group(1);
      final valueRaw = match.group(2);
      final value = int.tryParse(valueRaw ?? '');
      if (name == null || value == null) continue;
      result.putIfAbsent(name, () => value);
    }
    return result;
  }

  (int?, int?) _sumOutboundCounters(Map<String, int> counters) {
    int down = 0;
    int up = 0;
    bool found = false;
    for (final entry in counters.entries) {
      final name = entry.key;
      if (!name.startsWith('outbound>>>')) continue;
      if (name.contains('>>>api>>>') || name.contains('>>>block>>>')) {
        continue;
      }
      if (name.endsWith('>>>traffic>>>downlink')) {
        down += entry.value;
        found = true;
      } else if (name.endsWith('>>>traffic>>>uplink')) {
        up += entry.value;
        found = true;
      }
    }
    if (!found) return (null, null);
    return (down, up);
  }

  (int?, int?) _sumInboundCounters(Map<String, int> counters) {
    int down = 0;
    int up = 0;
    bool found = false;
    for (final entry in counters.entries) {
      final name = entry.key;
      if (!name.startsWith('inbound>>>')) continue;
      if (name.contains('>>>api-in>>>')) continue;
      if (name.endsWith('>>>traffic>>>downlink')) {
        down += entry.value;
        found = true;
      } else if (name.endsWith('>>>traffic>>>uplink')) {
        up += entry.value;
        found = true;
      }
    }
    if (!found) return (null, null);
    return (down, up);
  }

  void _resetConnectionLogging({required bool enableDiskLogging}) {
    _connectionLogDiskEnabled = enableDiskLogging;
    _connectionLogFile = null;
    _pendingConnectionLogLines.clear();
    _memoryConnectionLogLines.clear();
    _connectionLogFlushTimer?.cancel();
    _connectionLogFlushTimer = null;
    _connectionLogFlushInProgress = false;
    _droppedConnectionLogLines = 0;
    _connectionLogThrottleMarkerQueued = false;
  }

  void _beginConnectDiagnostics() {
    _lastConnectPhaseDurationsMs.clear();
    _lastConnectProcessLaunchCounts.clear();
  }

  Future<T> _measureConnectPhase<T>(
    String phase,
    Future<T> Function() action,
  ) async {
    final sw = Stopwatch()..start();
    try {
      return await action();
    } finally {
      _lastConnectPhaseDurationsMs[phase] = sw.elapsedMilliseconds;
    }
  }

  void _recordProcessLaunch(String category) {
    _lastConnectProcessLaunchCounts.update(
      category,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
  }

  String _categorizeProcessLaunch(String executable, List<String> arguments) {
    final normalized = executable.toLowerCase();
    if (normalized == 'powershell' || normalized.endsWith('\\powershell.exe')) {
      return 'powershell';
    }
    if (normalized == 'netsh' || normalized.endsWith('\\netsh.exe')) {
      return 'netsh';
    }
    if (normalized == 'taskkill' || normalized.endsWith('\\taskkill.exe')) {
      return 'taskkill';
    }
    if (arguments.isNotEmpty && arguments.first == 'api') {
      return 'xray api';
    }
    return 'xray-core';
  }

  Future<ProcessResult> _runMeasuredProcess(
    String executable,
    List<String> arguments,
  ) async {
    _recordProcessLaunch(_categorizeProcessLaunch(executable, arguments));
    return _processRunner(executable, arguments);
  }

  Future<Process> _startMeasuredProcess(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    _recordProcessLaunch(_categorizeProcessLaunch(executable, arguments));
    return _processStarter(executable, arguments, environment: environment);
  }

  void _emitConnectDiagnosticsIfNeeded({required bool success}) {
    if (!_isWindows) return;
    if (!_developerModeEnabled && success) return;
    if (_lastConnectPhaseDurationsMs.isEmpty &&
        _lastConnectProcessLaunchCounts.isEmpty) {
      return;
    }
    final phaseSummary = _lastConnectPhaseDurationsMs.entries
        .map((entry) => '${entry.key}=${entry.value}ms')
        .join(', ');
    final processSummary = _lastConnectProcessLaunchCounts.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(', ');
    if (phaseSummary.isNotEmpty) {
      _appendConnectionLog('[diag] phases: $phaseSummary');
    }
    if (processSummary.isNotEmpty) {
      _appendConnectionLog('[diag] processes: $processSummary');
    }
  }

  Future<void> _captureFailureDiagnostics(String message) async {
    _appendConnectionLog('[diag] failure: $message');
    _emitConnectDiagnosticsIfNeeded(success: false);
    await _enablePersistentConnectionLog(reason: 'connect-failed');
    await _flushConnectionLog(force: true);
  }

  Future<void> _enablePersistentConnectionLog({required String reason}) async {
    if (_connectionLogFile != null) {
      _connectionLogDiskEnabled = true;
      _appendConnectionLog('[diag] persistent log enabled: $reason');
      return;
    }
    _connectionLogDiskEnabled = true;
    await _createConnectionLogFile(reason: reason);
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
    final trimmed = log.trim();
    if (trimmed.isEmpty) return;
    _memoryConnectionLogLines.add(trimmed);
    if (_memoryConnectionLogLines.length > _maxMemoryConnectionLogLines) {
      _memoryConnectionLogLines.removeAt(0);
    }
    if (!_connectionLogDiskEnabled || _connectionLogFile == null) return;
    if (_pendingConnectionLogLines.length >= _maxPendingConnectionLogLines) {
      _droppedConnectionLogLines++;
      _connectionLogThrottleMarkerQueued = true;
      _scheduleConnectionLogFlush();
      return;
    }
    _pendingConnectionLogLines.add(trimmed);
    _scheduleConnectionLogFlush();
  }

  Future<void> _createConnectionLogFile({String? reason}) async {
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
      if (_memoryConnectionLogLines.isNotEmpty) {
        final seedPayload = '${_memoryConnectionLogLines.join('\n')}\n';
        await logFile.writeAsString(seedPayload, mode: FileMode.append);
      }
      _appendConnectionLog('Log file created: ${logFile.path}');
      if (reason != null && reason.isNotEmpty) {
        _appendConnectionLog('[diag] log file reason: $reason');
      }
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
    if (isError && !_isBenignWindowsCoreStderr(line)) {
      _lastStartError = line;
    }
  }

  bool _isBenignWindowsCoreStderr(String line) {
    final normalized = line.toLowerCase();
    return normalized.contains('using existing driver') ||
        normalized.contains('creating adapter') ||
        normalized.contains('removed orphaned adapter') ||
        normalized.contains('failed to find matching adapter name');
  }

  String? _latestMeaningfulProcessLog() {
    if (_lastStartError != null && _lastStartError!.isNotEmpty) {
      return _lastStartError;
    }
    for (final line in _recentLogs.reversed) {
      if (!_isBenignWindowsCoreStderr(line)) {
        return line;
      }
    }
    return _recentLogs.isNotEmpty ? _recentLogs.last : null;
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
      final routeSession =
          _sessionRoutePlans[token] ??
          (_activeConnectionToken == token ? _activeWindowsRouteSession : null);
      _appendConnectionLog(
        '[token=$token] cleanup started reason=$reason interface=${interfaceName ?? 'unknown'}',
      );
      if (_isWindows && routeSession != null) {
        final routeLogs = <String>[];
        await _windowsRouteManager.cleanupSession(
          routeSession,
          logs: routeLogs,
        );
        _emitLogs(routeLogs);
      }
      if (_isWindows &&
          interfaceName != null &&
          _isManagedTunPlanName(interfaceName)) {
        final cleanup = await _tunGuard.cleanupAdapter(interfaceName);
        _emitLogs(cleanup.logs);
      } else if (_isWindows && interfaceName != null) {
        _appendConnectionLog(
          '[token=$token] skipping adapter removal for runtime interface '
          '$interfaceName; Xray owns the adapter lifecycle',
        );
      }
      _sessionInterfaces.remove(token);
      _sessionRoutePlans.remove(token);
      if (_activeConnectionToken == token) {
        _activeConnectionToken = null;
        _activeInterfaceName = null;
        _activeWindowsRouteSession = null;
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
        const Duration(milliseconds: 900),
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
      if (_isWindows) {
        _appendConnectionLog('Waiting for Windows core readiness...');
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        var lastAdapterProbe = DateTime.fromMillisecondsSinceEpoch(0);
        while (DateTime.now().isBefore(deadline)) {
          final exitCode = await _tryReadEarlyExitCode(process);
          if (exitCode != null) {
            final hint = _latestMeaningfulProcessLog();
            final suffix = hint == null ? '' : ' ($hint)';
            _appendConnectionLog(
              'ERROR: xray-core exited early (code $exitCode)$suffix',
            );
            return 'xray-core exited early (code $exitCode)$suffix';
          }

          if (_hasTunReadySignal()) {
            _appendConnectionLog('Windows core reported TUN ready signal');
            return null;
          }

          final apiReady = await _isWindowsCoreApiResponsive();
          if (apiReady) {
            _appendConnectionLog(
              'Windows core is ready via xray runtime signal/API',
            );
            return null;
          }

          final now = DateTime.now();
          if (now.difference(lastAdapterProbe) >=
              const Duration(milliseconds: 900)) {
            lastAdapterProbe = now;
            final adapterUp = await _tunGuard.isAdapterUp(interfaceName);
            if (_hasTunReadySignal()) {
              _appendConnectionLog(
                'Windows core reported TUN ready signal after adapter probe',
              );
              return null;
            }
            if (adapterUp) {
              _appendConnectionLog('TUN adapter is up and ready');
              return null;
            }
          }

          await Future.delayed(const Duration(milliseconds: 80));
        }

        if (_hasTunReadySignal()) {
          _appendConnectionLog(
            'Windows core reported TUN ready signal at startup deadline',
          );
          return null;
        }
        final apiReady = await _isWindowsCoreApiResponsive();
        if (apiReady) {
          _appendConnectionLog(
            'Windows core is ready via API at startup deadline',
          );
          return null;
        }

        final hint = _latestMeaningfulProcessLog();
        final suffix = hint == null ? '' : ' ($hint)';
        _appendConnectionLog('ERROR: TUN adapter did not come up$suffix');
        return 'TUN adapter did not come up$suffix';
      }
      return null;
    } finally {
      _startupCheckInProgress = false;
    }
  }

  Future<int?> _tryReadEarlyExitCode(Process process) async {
    try {
      return await process.exitCode.timeout(const Duration(milliseconds: 1));
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _hasTunReadySignal() {
    for (final line in _recentLogs.reversed) {
      final normalized = line.toLowerCase();
      if (normalized.contains('proxy/tun:') && normalized.contains(' up')) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _isWindowsCoreApiResponsive() async {
    if (!_isWindows || _process == null) return false;
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        _xrayApiPort,
        timeout: const Duration(milliseconds: 120),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _warmupConnection() async {
    final process = _process;
    if (_isWindows && (process == null || !_windowsConnected)) return;

    // One bounded probe is enough to create a first flow for diagnostics.
    // A fan-out over popular sites made startup noisy and could race cleanup.
    await _warmupDomain('www.msftconnecttest.com');
    if (_isWindows && !identical(_process, process)) return;
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

class _WindowsRuntimeSessionState {
  const _WindowsRuntimeSessionState({
    required this.dirty,
    this.interfaceName,
    this.remoteHost,
    this.pid,
    this.updatedAt,
  });

  final bool dirty;
  final String? interfaceName;
  final String? remoteHost;
  final int? pid;
  final DateTime? updatedAt;

  factory _WindowsRuntimeSessionState.fromJson(Map<String, dynamic> json) {
    return _WindowsRuntimeSessionState(
      dirty: json['dirty'] == true,
      interfaceName: json['interfaceName'] as String?,
      remoteHost: json['remoteHost'] as String?,
      pid: json['pid'] is int
          ? json['pid'] as int
          : int.tryParse('${json['pid'] ?? ''}'),
      updatedAt: json['updatedAt'] is String
          ? DateTime.tryParse(json['updatedAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'dirty': dirty,
      'interfaceName': interfaceName,
      'remoteHost': remoteHost,
      'pid': pid,
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }
}

class _WindowsEndpointResolution {
  const _WindowsEndpointResolution({
    required this.routeHost,
    this.serverAddressOverride,
  });

  final String routeHost;
  final String? serverAddressOverride;
}

class _WindowsRuntimeSessionStore {
  const _WindowsRuntimeSessionStore();

  Future<File> _markerFile() async {
    final dir = Directory('${Directory.systemTemp.path}/neuravpn_runtime');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/windows_session_marker.json');
  }

  Future<_WindowsRuntimeSessionState> read() async {
    try {
      final file = await _markerFile();
      if (!await file.exists()) {
        return const _WindowsRuntimeSessionState(dirty: false);
      }
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const _WindowsRuntimeSessionState(dirty: false);
      }
      return _WindowsRuntimeSessionState.fromJson(decoded);
    } catch (_) {
      return const _WindowsRuntimeSessionState(dirty: false);
    }
  }

  Future<void> markDirty({
    String? interfaceName,
    String? remoteHost,
    int? pid,
  }) async {
    try {
      final file = await _markerFile();
      final state = _WindowsRuntimeSessionState(
        dirty: true,
        interfaceName: interfaceName,
        remoteHost: remoteHost,
        pid: pid,
        updatedAt: DateTime.now(),
      );
      await file.writeAsString(jsonEncode(state.toJson()), flush: true);
    } catch (_) {
      // Best-effort marker update.
    }
  }

  Future<void> clear() async {
    try {
      final file = await _markerFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort marker cleanup.
    }
  }
}
