import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:device_apps/device_apps.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'vless/vless_parser.dart';
import 'models/split_tunnel_config.dart';
import 'models/split_tunnel_preset.dart';
import 'models/connectivity_test.dart';
import 'models/vpn_subscription.dart';
import 'services/connectivity_targets.dart';
import 'services/connectivity_tester.dart';
import 'services/dpi_evasion_config.dart';
import 'services/dpi_evasion_manager.dart';
import 'services/smart_route_engine.dart';
import 'services/singbox_controller.dart';
import 'services/subscription_repository.dart';
import 'services/subscription_manager.dart';
import 'models/vpn_profile.dart';
import 'widgets/profile_list_view.dart';
import 'widgets/add_profile_dialog.dart';
import 'widgets/dpi_evasion_widget.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru_RU', null);
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    final windowOptions = WindowOptions(
      size: Platform.isWindows ? Size(480, 860) : Size(1100, 760),
      minimumSize: Platform.isWindows ? Size(360, 640) : Size(900, 640),
      center: true,
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.normal,
      title: 'VLESS VPN Client',
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  runApp(const VpnApp());
}

class VpnApp extends StatelessWidget {
  const VpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFF1E3C),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'VLESS VPN Client',
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF050608),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
      ),
      home: const VlessHomePage(),
    );
  }
}

class VlessHomePage extends StatefulWidget {
  const VlessHomePage({super.key});

  @override
  State<VlessHomePage> createState() => _VlessHomePageState();
}

class _VlessHomePageState extends State<VlessHomePage>
    with TrayListener, WindowListener, SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  String _status = '\u041e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e';
  final Map<String, SplitTunnelConfig> _splitConfigs = {
    'all': SplitTunnelConfig(mode: 'all'),
    'whitelist': SplitTunnelConfig(mode: 'whitelist'),
    'blacklist': SplitTunnelConfig(mode: 'blacklist'),
  };
  String _splitMode = 'all';
  List<SplitTunnelPreset> _splitPresets = [];
  String? _activePresetName;
  bool _presetDirty = false;
  List<VpnProfile> _profiles = [];
  VpnProfile? _selectedProfile;
  final SingBoxController _singBoxController = SingBoxController();
  final ScrollController _logScrollController = ScrollController();
  final TrayManager _trayManager = TrayManager.instance;
  bool _trayInitialized = false;
  bool _isExitingApp = false;
  bool _isConnecting = false;
  bool _hasSubscriptions = false;
  late final AnimationController _connectGlowController;
  bool _androidAppsLoaded = false;
  bool _androidAppsLoading = false;
  String? _androidAppLoadError;
  List<Application> _androidInstalledApps = const <Application>[];
  Map<String, String> _androidAppLabels = {};
  static const String _splitConfigPrefsKey = 'split_tunnel_state_v2';
  static const String _legacySplitConfigKey = 'split_tunnel_config_v1';
  static const String _trayShowKey = 'show';
  static const String _trayExitKey = 'exit';
  static const String _noPresetValue = '__none__';
  static const String _splitToggleKey = 'split_tunnel_enabled';
  static const String _smartRoutingKey = 'smart_routing_enabled';
  static const String _hasEverAddedKeyKey = 'has_added_key';
  int? _pingMs;
  bool _pingInProgress = false;
  bool _splitEnabled = false;
  final Map<String, int> _profilePings = {};
  final List<String> _logLines = <String>[];
  int _profileNameCounter = 0;
  int _subscriptionsRefreshToken = 0;
  static const String _profileMetricsKey = 'vpn_profile_metrics';
  static const String _profileCounterKey = 'vpn_profile_counter';
  bool _developerMode = false;
  bool _smartRouting = false;
  bool _hasEverAddedKey = false;
  static const String _dpiAggressiveKey = 'dpi_evasion_aggressive';
  final SmartRouteEngine _smartRouteEngine = SmartRouteEngine();
  final ConnectivityTester _connectivityTester = ConnectivityTester();
  late final List<ConnectivityTestTarget> _connectivityTargets =
      buildDefaultConnectivityTargets();
  final DpiEvasionManager _dpiEvasionManager = DpiEvasionManager();
  DpiEvasionConfig _dpiEvasionConfig = DpiEvasionConfig.balanced;
  final Map<String, ConnectivityTestResult> _connectivityResults = {};
  bool _isConnectivityTesting = false;
  int _connectivityCompleted = 0;
  DateTime? _connectivityLastRun;
  bool _cancelConnectivity = false;

  VlessLink? get _parsed => _singBoxController.parsedLink;
  VlessLink? get _currentLink =>
      _parsed ?? parseVlessUri(_controller.text.trim());
  File? get _configFile => _singBoxController.configFile;
  String? get _generatedConfig => _singBoxController.generatedConfig;
  bool get _isDesktopPlatform =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  bool get _hasActivePreset =>
      _activePresetName != null &&
      _splitPresets.any((preset) => preset.name == _activePresetName);
  String get _activePresetLabel {
    if (_activePresetName == null) {
      return _presetDirty ? 'Свои *' : 'Свои';
    }
    return _presetDirty ? '${_activePresetName!}*' : _activePresetName!;
  }

  String get _pingLabel => _pingInProgress
      ? 'Измерение...'
      : (_pingMs != null ? '$_pingMs мс' : '--');
  SplitTunnelConfig get _activeSplitConfig =>
      _splitConfigs[_splitMode] ?? _splitConfigs['all']!;
  SplitTunnelConfig get _effectiveSplitConfig =>
      _splitEnabled ? _activeSplitConfig : SplitTunnelConfig(mode: 'all');
  SplitTunnelConfig get _configForConnection => _effectiveSplitConfig.copyWith(
    smartRouting: _smartRouting,
    smartDomains: _smartRouteEngine.exportLegacyRuleEntries(),
  );
  @override
  void initState() {
    super.initState();
    _connectGlowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _loadInitialData();
    _checkWintun();
    if (_isDesktopPlatform) {
      windowManager.addListener(this);
      _trayManager.addListener(this);
      unawaited(_initDesktopShell());
    }
    if (Platform.isAndroid) {
      unawaited(_loadAndroidApps());
    }
  }

  Future<void> _checkWintun() async {
    final available = await _singBoxController.isWintunAvailable();
    if (!available && mounted) {
      _showFastSnack('wintun.dll ?? ??????');
    }
  }

  Future<void> _loadAndroidApps({bool force = false}) async {
    if (!Platform.isAndroid) return;
    if (_androidAppsLoading) return;
    if (_androidAppsLoaded && !force) return;
    if (!mounted) return;
    setState(() {
      _androidAppsLoading = true;
      if (force) {
        _androidAppLoadError = null;
      }
    });
    try {
      final apps = await DeviceApps.getInstalledApplications(
        includeAppIcons: false,
        includeSystemApps: false,
        onlyAppsWithLaunchIntent: true,
      );
      apps.sort(
        (a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        _androidInstalledApps = apps;
        _androidAppLabels = {
          for (final app in apps) app.packageName: app.appName,
        };
        _androidAppsLoaded = true;
        _androidAppsLoading = false;
        _androidAppLoadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _androidAppsLoading = false;
        _androidAppLoadError = e.toString();
      });
    }
  }

  Future<void> _showAndroidAppPicker() async {
    if (!Platform.isAndroid) return;
    if (!_androidAppsLoaded && !_androidAppsLoading) {
      await _loadAndroidApps();
    }
    if (!mounted) return;
    final apps = _androidInstalledApps;
    if (apps.isEmpty) {
      _showFastSnack(
        'Список приложений пуст. Обновите список и попробуйте снова.',
      );
      return;
    }
    final package = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _AndroidAppPickerSheet(apps: apps),
    );
    if (package == null || package.isEmpty) return;
    _addApplication('package:$package');
  }

  Widget _buildAndroidAppActions(ThemeData theme) {
    final canPick = _androidAppsLoaded || !_androidAppsLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            TextButton.icon(
              onPressed: canPick ? _showAndroidAppPicker : null,
              icon: const Icon(Icons.apps_outlined),
              label: const Text('Выбрать приложение из списка'),
            ),
            TextButton.icon(
              onPressed: _androidAppsLoading
                  ? null
                  : () => _loadAndroidApps(force: true),
              icon: const Icon(Icons.refresh_outlined),
              label: const Text('Обновить список'),
            ),
            if (_androidAppsLoading)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (_androidAppLoadError != null)
          Text(
            'Не удалось загрузить приложения: $_androidAppLoadError',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          )
        else
          Text(
            'Список приложений готов. Можно добавить из списка или ввести package name вручную.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
      ],
    );
  }

  String _describeApplicationEntry(String value) {
    if (value.startsWith('package:')) {
      final package = value.substring('package:'.length);
      final name = _androidAppLabels[package];
      if (name != null && name.isNotEmpty) {
        return '$name ($package)';
      }
      return package;
    }
    return value;
  }

  void _showFastSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  bool get _isRunning => _singBoxController.isRunning;


  Future<void> _loadInitialData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedProfiles = prefs.getString('vpn_profiles');
    var profiles = VpnProfile.listFromJsonString(savedProfiles);
    final storedCounter = prefs.getInt(_profileCounterKey) ?? 0;
    final metricsRaw = prefs.getString(_profileMetricsKey);
    final restoredPings = <String, int>{};
    bool splitEnabled = prefs.getBool(_splitToggleKey) ?? true;
    _smartRouting = prefs.getBool(_smartRoutingKey) ?? false;
    _developerMode = prefs.getBool('developer_mode') ?? false;
    final dpiAggressive = prefs.getBool(_dpiAggressiveKey) ?? false;

    if (metricsRaw != null && metricsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(metricsRaw);
        if (decoded is Map<String, dynamic>) {
          decoded.forEach((key, value) {
            if (value is Map) {
              final ping = value['ping'];
              if (ping is int) {
                restoredPings[key] = ping;
              }
            }
          });
        }
      } catch (_) {
        // ignore invalid metrics payload
      }
    }

    if (profiles.isEmpty) {
      final legacyUri = prefs.getString('vless_uri');
      if (legacyUri != null && legacyUri.isNotEmpty) {
        profiles = [VpnProfile(name: 'Profile 1', uri: legacyUri)];
      }
    }

    VpnProfile? selected;
    final selectedName = prefs.getString('vpn_profile_selected');
    if (selectedName != null) {
      for (final profile in profiles) {
        if (profile.name == selectedName) {
          selected = profile;
          break;
        }
      }
    }
    selected ??= profiles.isNotEmpty ? profiles.first : null;

    final repository = SubscriptionRepository();
    final subscriptions = await repository.getAllSubscriptions();
    _hasSubscriptions = subscriptions.isNotEmpty;
    final storedHasKey = prefs.getBool(_hasEverAddedKeyKey) ?? false;
    _hasEverAddedKey = storedHasKey || profiles.isNotEmpty || subscriptions.isNotEmpty;
    if (_hasEverAddedKey && !storedHasKey) {
      await prefs.setBool(_hasEverAddedKeyKey, true);
    }

    final rawState =
        prefs.getString(_splitConfigPrefsKey) ??
        prefs.getString(_legacySplitConfigKey);
    String? restoredMode;
    Map<String, SplitTunnelConfig>? restoredMap;
    List<SplitTunnelPreset>? restoredPresets;
    String? restoredPresetName;
    if (rawState != null) {
      try {
        final decoded = jsonDecode(rawState);
        if (decoded is Map<String, dynamic>) {
          if (decoded['configs'] is Map) {
            final configsJson = decoded['configs'] as Map;
            final mapped = <String, SplitTunnelConfig>{};
            configsJson.forEach((key, value) {
              final normalizedMode = _normalizeSplitMode(key?.toString());
              mapped[normalizedMode] = SplitTunnelConfig.fromJson(
                value is Map<String, dynamic> ? value : null,
                fallbackMode: normalizedMode,
              );
            });
            restoredMap = mapped;
            restoredMode = _normalizeSplitMode(decoded['mode']?.toString());
            final presetName = decoded['activePreset'];
            if (presetName is String && presetName.isNotEmpty) {
              restoredPresetName = presetName;
            }
            if (decoded['enabled'] is bool) {
              splitEnabled = decoded['enabled'] as bool;
            }
            if (decoded['smartRouting'] is bool) {
              _smartRouting = decoded['smartRouting'] as bool;
            }

            if (decoded['presets'] is List) {
              restoredPresets = (decoded['presets'] as List)
                  .whereType<Map<String, dynamic>>()
                  .map(SplitTunnelPreset.fromJson)
                  .toList();
            }
          } else {
            final legacyDomains =
                _normalizeStringList(decoded['domains']) ?? const <String>[];
            final legacyApps =
                _normalizeStringList(decoded['applications']) ??
                const <String>[];
            final mode = _normalizeSplitMode(decoded['mode']?.toString());
            restoredMode = mode;
            restoredMap = {
              mode: SplitTunnelConfig(
                mode: mode,
                domains: legacyDomains,
                applications: legacyApps,
              ),
            };
          }
        }
      } catch (_) {
        // ignore corrupted prefs
      }
    }

    if (!mounted) return;
    final smartRoutingFlag = _smartRouting;
    setState(() {
      _profiles = profiles;
      _profileNameCounter = math.max(
        storedCounter,
        _findMaxProfileIndex(profiles),
      );
      _selectedProfile = selected;
      _syncMetricsFromProfile(selected);
      _smartRouting = smartRoutingFlag;
      _dpiEvasionConfig = dpiAggressive
          ? DpiEvasionConfig.aggressive
          : DpiEvasionConfig.balanced;
      if (restoredMap != null) {
        for (final entry in _splitConfigs.keys.toList()) {
          final restored = restoredMap[entry];
          _splitConfigs[entry] = (restored ?? SplitTunnelConfig(mode: entry))
              .copyWith(mode: entry);
        }
      }
      if (restoredMode != null) {
        _splitMode = restoredMode;
      }
      if (restoredPresets != null) {
        _splitPresets = restoredPresets;
      }
      if (restoredPresetName != null) {
        _activePresetName = restoredPresetName;
        _presetDirty = false;
      } else {
        _presetDirty = false;
      }
      _splitEnabled = splitEnabled;
      _profilePings
        ..clear()
        ..addAll(restoredPings);
    });

    if (selected != null) {
      _controller.text = selected.uri;
    } else {
      final fallbackUri = prefs.getString('vless_uri');
      if (fallbackUri != null && fallbackUri.isNotEmpty) {
        _controller.text = fallbackUri;
      }
    }
  }

  String _normalizeSplitMode(String? raw) {
    switch (raw) {
      case 'all':
        return 'all';
      case 'whitelist':
        return 'whitelist';
      case 'blacklist':
        return 'blacklist';
      default:
        return 'all';
    }
  }

  List<String>? _normalizeStringList(dynamic value) {
    if (value is! List) return null;
    final result = <String>[];
    for (final entry in value) {
      final normalized = _normalizeEntry(entry == null ? '' : entry.toString());
      if (normalized.isNotEmpty) {
        result.add(normalized);
      }
    }
    return result;
  }

  Future<void> _persistProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    if (_profiles.isEmpty) {
      await prefs.remove('vpn_profiles');
    } else {
      await prefs.setString(
        'vpn_profiles',
        VpnProfile.listToJsonString(_profiles),
      );
    }
    await prefs.setInt(_profileCounterKey, _profileNameCounter);
  }

  Future<void> _persistSelectedProfile() async {
    final prefs = await SharedPreferences.getInstance();
    if (_selectedProfile != null) {
      await prefs.setString('vpn_profile_selected', _selectedProfile!.name);
    } else {
      await prefs.remove('vpn_profile_selected');
    }
  }

  Future<void> _persistProfileMetrics() async {
    final prefs = await SharedPreferences.getInstance();
    if (_profilePings.isEmpty) {
      await prefs.remove(_profileMetricsKey);
      return;
    }
    final payload = <String, Map<String, dynamic>>{};
    for (final entry in _profilePings.entries) {
      payload.putIfAbsent(entry.key, () => <String, dynamic>{})['ping'] =
          entry.value;
    }
    await prefs.setString(_profileMetricsKey, jsonEncode(payload));
  }

  Future<void> _saveUri() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vless_uri', _controller.text.trim());
  }

  Future<void> _persistSplitState() async {
    final prefs = await SharedPreferences.getInstance();
    final configsPayload = _splitConfigs.map(
      (key, value) => MapEntry(key, value.copyWith(mode: key).toJson()),
    );
    final payload = jsonEncode({
      'mode': _splitMode,
      'configs': configsPayload,
      'presets': _splitPresets.map((preset) => preset.toJson()).toList(),
      'activePreset': _activePresetName,
      'enabled': _splitEnabled,
      'smartRouting': _smartRouting,
    });
    await prefs.setString(_splitConfigPrefsKey, payload);
    await prefs.remove(_legacySplitConfigKey);
    await prefs.setBool(_splitToggleKey, _splitEnabled);
    await prefs.setBool(_smartRoutingKey, _smartRouting);
  }

  void _updateActiveSplitConfig(SplitTunnelConfig config) {
    setState(() {
      _splitConfigs[_splitMode] = config.copyWith(mode: _splitMode);
      if (_activePresetName != null) {
        _presetDirty = true;
      } else {
        _presetDirty = false;
      }
    });
    unawaited(_persistSplitState());
  }

  void _changeSplitMode(String mode) {
    final normalized = _normalizeSplitMode(mode);
    if (_splitMode == normalized) return;
    final current = _activeSplitConfig;
    final hadPreset = _hasActivePreset;
    _splitConfigs[normalized] = current.copyWith(mode: normalized);
    setState(() {
      _splitMode = normalized;
      if (hadPreset) {
        _presetDirty = true;
      } else {
        _activePresetName = null;
        _presetDirty = false;
      }
    });
    unawaited(_persistSplitState());
  }

  Future<void> _setSplitEnabled(bool enabled) async {
    if (_splitEnabled == enabled) return;
    setState(() => _splitEnabled = enabled);
    await _persistSplitState();
  }

  Future<int?> _measurePing(String host, int port) async {
    const attempts = 4;
    final results = <int>[];
    for (var i = 0; i < attempts; i++) {
      final sw = Stopwatch()..start();
      try {
        final socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 3),
        );
        results.add(sw.elapsedMilliseconds);
        socket.destroy();
      } catch (_) {
        // ignore attempt errors
      }
    }
    if (results.isEmpty) return null;
    final avg = results.reduce((a, b) => a + b) / results.length;
    return avg.round();
  }

  Future<void> _refreshMetrics({bool silent = false}) async {
    if (_pingInProgress) return;
    final link = _currentLink;
    if (link == null) {
      if (!silent) {
        _showFastSnack('Select a profile with a valid VLESS URI first.');
      }
      return;
    }
    setState(() {
      _pingInProgress = true;
    });

    final ping = await _measurePing(link.host, link.port);

    if (!mounted) return;
    setState(() {
      _pingMs = ping;
      _pingInProgress = false;
      final profileName = _selectedProfile?.name;
      if (profileName != null && ping != null) {
        _profilePings[profileName] = ping;
      }
    });
    await _persistProfileMetrics();
    if (!silent && ping != null) {
      _showFastSnack('Метрики обновлены');
    }
  }

  void _syncMetricsFromProfile(VpnProfile? profile) {
    if (profile == null) {
      _pingMs = null;
      return;
    }
    _pingMs = _profilePings[profile.name];
  }

  Future<void> _initDesktopShell() async {
    if (!_isDesktopPlatform) return;
    await windowManager.setPreventClose(true);
    await _setupTrayIcon();
  }

  Future<void> _setupTrayIcon() async {
    if (_trayInitialized) return;
    final iconPath = await _prepareTrayIconFile();
    await _trayManager.setIcon(iconPath);
    await _trayManager.setToolTip('HappyCat VPN Client');
    final menu = Menu(
      items: [
        MenuItem(key: _trayShowKey, label: 'Показать окно'),
        MenuItem.separator(),
        MenuItem(key: _trayExitKey, label: 'Выход'),
      ],
    );
    await _trayManager.setContextMenu(menu);
    _trayInitialized = true;
  }

  Future<String> _prepareTrayIconFile() async {
    const assetKey = 'windows/runner/resources/app_icon.ico';
    final data = await rootBundle.load(assetKey);
    final tmpDir = await getTemporaryDirectory();
    final file = File('${tmpDir.path}/happycat_tray.ico');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file.path;
  }

  Future<void> _restoreWindowFromTray() async {
    if (!_isDesktopPlatform) return;
    final isVisible = await windowManager.isVisible();
    if (!isVisible) {
      await windowManager.show();
    }
    await windowManager.focus();
  }

  Future<void> _handleTrayExit() async {
    if (_isExitingApp) return;
    _isExitingApp = true;
    await _singBoxController.dispose();
    if (!_isDesktopPlatform) {
      exit(0);
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_restoreWindowFromTray());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _trayShowKey:
        unawaited(_restoreWindowFromTray());
        break;
      case _trayExitKey:
        unawaited(_handleTrayExit());
        break;
    }
  }

  @override
  void onWindowClose() {
    if (_isExitingApp) {
      return;
    }
    unawaited(windowManager.hide());
  }

  Future<void> _promptSavePreset() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _PresetNameDialog(initialValue: _defaultPresetName()),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    _savePreset(trimmed);
  }

  void _savePreset(String name) {
    final sanitized = name.trim();
    if (sanitized.isEmpty) return;
    final preset = SplitTunnelPreset(
      name: sanitized,
      mode: _splitMode,
      domains: List<String>.from(_activeSplitConfig.domains),
      applications: List<String>.from(_activeSplitConfig.applications),
    );
    setState(() {
      final remaining = _splitPresets
          .where((p) => p.name != preset.name)
          .toList();
      _splitPresets = [preset, ...remaining];
      _activePresetName = preset.name;
      _presetDirty = false;
    });
    unawaited(_persistSplitState());
    _showFastSnack('Text');
  }

  void _overwriteActivePreset() {
    if (!_hasActivePreset) return;
    final name = _activePresetName;
    if (name == null) return;
    final preset = SplitTunnelPreset(
      name: name,
      mode: _splitMode,
      domains: List<String>.from(_activeSplitConfig.domains),
      applications: List<String>.from(_activeSplitConfig.applications),
    );
    setState(() {
      _splitPresets = [preset, ..._splitPresets.where((p) => p.name != name)];
      _presetDirty = false;
    });
    unawaited(_persistSplitState());
    _showFastSnack('Пресет обновлён');
  }

  void _applyPreset(SplitTunnelPreset preset, {bool silent = false}) {
    final targetMode = _normalizeSplitMode(preset.mode);
    setState(() {
      _splitConfigs[targetMode] = SplitTunnelConfig(
        mode: targetMode,
        domains: List<String>.from(preset.domains),
        applications: List<String>.from(preset.applications),
      );
      _splitMode = targetMode;
      _activePresetName = preset.name;
      _presetDirty = false;
    });
    unawaited(_persistSplitState());
    if (!silent) {
      _showFastSnack('Пресет применён');
    }
  }

  void _handlePresetSelection(String value) {
    if (value == _noPresetValue) {
      setState(() {
        _activePresetName = null;
        _presetDirty = false;
      });
      unawaited(_persistSplitState());
      return;
    }
    for (final preset in _splitPresets) {
      if (preset.name == value) {
        _applyPreset(preset, silent: true);
        return;
      }
    }
  }

  Future<void> _confirmDeletePreset(SplitTunnelPreset preset) async {
    final shouldDelete =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Удалить пресет'),
            content: Text('Удалить пресет "${preset.name}"?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Удалить'),
              ),
            ],
          ),
        ) ??
        false;
    if (!shouldDelete) return;
    setState(() {
      _splitPresets = _splitPresets
          .where((p) => p.name != preset.name)
          .toList();
      if (_activePresetName == preset.name) {
        _activePresetName = null;
        _presetDirty = false;
      }
    });
    unawaited(_persistSplitState());
    _showFastSnack('Пресет удалён');
  }

  String _defaultPresetName() => _ensureUniquePresetName('Новый пресет');

  String _ensureUniquePresetName(String base) {
    if (_splitPresets.every((preset) => preset.name != base)) return base;
    var counter = 2;
    while (true) {
      final candidate = '$base ($counter)';
      if (_splitPresets.every((preset) => preset.name != candidate)) {
        return candidate;
      }
      counter++;
    }
  }

  Future<void> _addProfile(String name, String uri) async {
    final trimmedUri = uri.trim();
    if (trimmedUri.isEmpty) return;
    final autoName = _deriveProfileNameFromUri(trimmedUri);
    final uniqueName = _allocateProfileName(autoName.isEmpty ? _previewProfileName() : autoName);
    final profile = VpnProfile(name: uniqueName, uri: trimmedUri);

    setState(() {
      _profiles = [..._profiles, profile];
      _selectedProfile = profile;
      _hasEverAddedKey = true;
      _syncMetricsFromProfile(profile);
    });
    _controller.text = trimmedUri;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hasEverAddedKeyKey, true);
    await _persistProfiles();
    await _persistSelectedProfile();

    // UX: don't mix standalone keys with subscriptions.
    final repository = SubscriptionRepository();
    await repository.clearAllSubscriptions();
    if (!mounted) return;
    setState(() => _subscriptionsRefreshToken += 1);
  }

  Future<void> _removeProfileByName(String name) async {
    final updated = _profiles.where((profile) => profile.name != name).toList();
    setState(() {
      _profiles = updated;
      _profilePings.remove(name);
      if (_selectedProfile?.name == name) {
        _selectedProfile = updated.isNotEmpty ? updated.first : null;
        _controller.text = _selectedProfile?.uri ?? '';
      }
      _syncMetricsFromProfile(_selectedProfile);
    });
    await _persistProfiles();
    await _persistSelectedProfile();
    await _persistProfileMetrics();
    if (_profiles.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('vless_uri');
    }
  }

  Future<void> _showProfileDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => const AddProfileDialog(),
    );

    if (result == null) return;

    final input = result['input'] as String;
    final isVless = result['isVless'] as bool;

    if (isVless) {
      // Это прямой VLESS ключ
      final autoName = _deriveProfileNameFromUri(input);
      final displayName = autoName.isEmpty ? _previewProfileName() : autoName;
      await _addProfile(displayName, input);
    } else {
      // Это подписка - добавляем в репозиторий
      await _addSubscription(input, _deriveSubscriptionNameFromUrl(input));
    }
  }

  Future<void> _pasteProfileFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      _showFastSnack('\u0411\u0443\u0444\u0435\u0440 \u043e\u0431\u043c\u0435\u043d\u0430 \u043f\u0443\u0441\u0442');
      return;
    }
    if (raw.startsWith('vless://')) {
      final autoName = _deriveProfileNameFromUri(raw);
      await _addProfile(autoName.isEmpty ? _previewProfileName() : autoName, raw);
      return;
    }
    await _addSubscription(raw, _deriveSubscriptionNameFromUrl(raw));
  }

  Future<void> _addSubscription(String url, String name) async {
    try {
      final manager = SubscriptionService();
      final profiles = await manager.fetchSubscription(url);
      if (profiles.isEmpty) {
        throw 'Subscription did not return profiles';
      }

      final subscription = VpnSubscription(
        name: _deriveSubscriptionNameFromUrl(url),
        url: url,
        profiles: profiles,
      );

      final repository = SubscriptionRepository();
      final added = await repository.addSubscription(subscription);

      if (added) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_hasEverAddedKeyKey, true);
        setState(() => _hasEverAddedKey = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Subscription added')),
        );
        await _clearAllProfilesForSubscriptionMode();
        await _reloadSubscriptions();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to add: duplicate URL')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _reloadSubscriptions() async {
    final repository = SubscriptionRepository();
    final subs = await repository.getAllSubscriptions();
    if (!mounted) return;
    setState(() {
      _subscriptionsRefreshToken += 1;
      _hasSubscriptions = subs.isNotEmpty;
    });
  }

  Future<void> _clearAllProfilesForSubscriptionMode() async {
    if (!mounted) return;
    setState(() {
      _profiles = [];
      _selectedProfile = null;
      _profilePings.clear();
      _pingMs = null;
      _controller.text = '';
      _syncMetricsFromProfile(null);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('vless_uri');
    await _persistProfiles();
    await _persistSelectedProfile();
    await _persistProfileMetrics();
  }

  String _ensureUniqueProfileName(String base, {String? skipName}) {
    bool exists(String candidate) {
      for (final profile in _profiles) {
        if (profile.name == candidate && profile.name != skipName) {
          return true;
        }
      }
      return false;
    }

    if (!exists(base)) return base;
    var counter = 2;
    while (true) {
      final candidate = '$base ($counter)';
      if (!exists(candidate)) {
        return candidate;
      }
      counter++;
    }
  }

  int _findMaxProfileIndex(List<VpnProfile> profiles) {
    final regex = RegExp(r'^Profile\s+(\d+)$');
    var maxValue = 0;
    for (final profile in profiles) {
      final match = regex.firstMatch(profile.name);
      if (match != null) {
        final value = int.tryParse(match.group(1) ?? '');
        if (value != null) {
          maxValue = math.max(maxValue, value);
        }
      }
    }
    return maxValue;
  }

  String _allocateProfileName(String rawName) {
    final trimmed = rawName.trim();
    if (trimmed.isNotEmpty) {
      return _ensureUniqueProfileName(trimmed);
    }
    _profileNameCounter = math.max(
      _profileNameCounter,
      _findMaxProfileIndex(_profiles),
    );
    _profileNameCounter += 1;
    final generated = 'Profile $_profileNameCounter';
    return _ensureUniqueProfileName(generated);
  }

  String _mapStatus(String value) {
    final normalized = value.toLowerCase();
    if (normalized.contains('connect')) {
      return '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0430\u0435\u0442\u0441\u044f';
    }
    if (normalized.contains('connected') || normalized.contains('running')) {
      return '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u043e';
    }
    if (normalized.contains('disconnect')) {
      return '\u041e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e';
    }
    return _status;
  }

  String _deriveProfileNameFromUri(String uri) {
    final parsed = parseVlessUri(uri);
    if (parsed == null) return '';
    if (parsed.sni != null && parsed.sni!.isNotEmpty) return parsed.sni!;
    if (parsed.host.isNotEmpty) return parsed.host;
    if (parsed.tag != null && parsed.tag!.isNotEmpty) return parsed.tag!;
    return '';
  }

  String _deriveSubscriptionNameFromUrl(String url) {
    Uri? parsed = Uri.tryParse(url.trim());
    if (parsed == null || parsed.host.isEmpty) {
      parsed = Uri.tryParse('https://${url.trim()}');
    }
    final host = parsed?.host ?? '';
    return host.isNotEmpty ? host : 'Subscription';
  }

  String _previewProfileName() {
    final nextIndex =
        math.max(_profileNameCounter, _findMaxProfileIndex(_profiles)) + 1;
    return _ensureUniqueProfileName('Profile $nextIndex');
  }

  /// Выбрать профиль для текущего подключения (из подписки или обычный)
  Future<void> _selectCurrentProfile(VpnProfile profile) async {
    setState(() {
      _selectedProfile = profile;
      _controller.text = profile.uri;
      _syncMetricsFromProfile(profile);
    });
    // Для профилей из подписки не сохраняем выбор
    // Только для постоянных профилей
    if (_profiles.any((p) => p.name == profile.name)) {
      await _persistSelectedProfile();
    }
  }

  Future<void> _start() async {
    if (_isRunning) {
      await _stop();
      await Future.delayed(const Duration(seconds: 2));
    }

    setState(() {
      _status = '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0430\u0435\u0442\u0441\u044f';
      _isConnecting = true;
      _logLines.clear();
    });

    final result = await _singBoxController.connect(
      rawUri: _controller.text,
      splitConfig: _configForConnection,
      smartRouteEngine: _smartRouteEngine,
      dpiEvasionConfig: _dpiEvasionConfig,
      onStatus: (value) {
        if (!mounted) return;
        setState(() => _status = _mapStatus(value));
      },
      onLog: (line) => _appendLogs([line]),
    );

    if (!result.success) {
      if (!mounted) return;
      _showFastSnack(result.errorMessage ?? '\u041e\u0448\u0438\u0431\u043a\u0430 \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u044f');
      setState(() {
        _status = '\u041e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e';
        _isConnecting = false;
      });
      return;
    }

    await _saveUri();
    if (!mounted) return;
    setState(() {
      _status = '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u043e';
      _isConnecting = false;
    });
    unawaited(_applyDpiEvasionInjector());
    unawaited(_refreshMetrics(silent: true));
  }

  Future<void> _stop() async {
    if (!_isRunning) return;
    await _singBoxController.disconnect(
      onStatus: (value) {
        if (!mounted) return;
        setState(() => _status = _mapStatus(value));
      },
      onLog: (line) => _appendLogs([line]),
    );
    await _dpiEvasionManager.stopNativeInjector();
    if (!mounted) return;
    setState(() {
      _status = '\u041e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e';
      _isConnecting = false;
    });
  }

  Future<void> _applyDpiEvasionInjector() async {
    if (!_dpiEvasionConfig.enableTtlPhantom) {
      await _dpiEvasionManager.stopNativeInjector();
      return;
    }
    final link = _currentLink;
    if (link == null) return;
    await _dpiEvasionManager.startForHost(link.host, link.port);
  }

  void _updateDpiConfig(DpiEvasionConfig config) {
    setState(() => _dpiEvasionConfig = config);
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setBool(
          _dpiAggressiveKey,
          config.profile == DpiEvasionProfile.aggressive,
        ),
      ),
    );
    if (_isRunning) {
      unawaited(_applyDpiEvasionInjector());
    } else if (!config.enableTtlPhantom) {
      unawaited(_dpiEvasionManager.stopNativeInjector());
    }
  }

  void _appendLogs(Iterable<String> entries) {
    if (!mounted) return;
    final iterable = entries.where((e) => e.trim().isNotEmpty).toList();
    if (iterable.isEmpty) return;
    setState(() {
      for (final line in iterable) {
        _logLines.add(line);
        if (_logLines.length > 200) {
          _logLines.removeAt(0);
        }
      }
    });
  }


  void _showConfigDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Конфигурация sing-box'),
        insetPadding: EdgeInsets.symmetric(
          horizontal: (Platform.isAndroid || Platform.isIOS) ? 12 : 40,
          vertical: 24,
        ),
        content: SizedBox(
          width: math.min(MediaQuery.of(ctx).size.width, 900),
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: SelectableText(
                  _generatedConfig ?? '',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _connectGlowController.dispose();
    _controller.dispose();
    _logScrollController.dispose();
    if (_isDesktopPlatform) {
      windowManager.removeListener(this);
      _trayManager.removeListener(this);
      unawaited(_trayManager.destroy());
    }
    unawaited(_singBoxController.dispose());
    unawaited(_dpiEvasionManager.stopNativeInjector());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasConnectable = _profiles.isNotEmpty || _hasSubscriptions;
    if (!hasConnectable) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('VLESS VPN Client'),
        ),
        body: _buildEmptyState(),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('VLESS VPN Client'),
          bottom: TabBar(
            isScrollable: true,
            tabs: const [
              Tab(text: '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u0435'),
              Tab(text: '\u0420\u0430\u0437\u0434\u0435\u043b\u0435\u043d\u0438\u0435'),
              Tab(text: '\u041f\u0440\u043e\u0432\u0435\u0440\u043a\u0430 \u0441\u0432\u044f\u0437\u0438'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildConnectionTab(),
            _buildSplitTunnelTab(),
            _buildConnectivityTestTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.25),
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  onPressed: _showProfileDialog,
                  child: const Text('\u0412\u0432\u0435\u0441\u0442\u0438 \u043a\u043b\u044e\u0447'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _pasteProfileFromClipboard,
                  child: const Text('\u0412\u0441\u0442\u0430\u0432\u0438\u0442\u044c \u0438\u0437 \u0431\u0443\u0444\u0435\u0440\u0430 \u043e\u0431\u043c\u0435\u043d\u0430'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionTab() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _buildStatusHero(context, isWide),
                const SizedBox(height: 18),
                _buildProfileCard(context),
                const SizedBox(height: 18),
                _buildLogPanel(context),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSplitTunnelTab() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;
        final theme = Theme.of(context);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (!_splitEnabled)
                  Card(
                    color: theme.colorScheme.errorContainer.withOpacity(0.2),
                    elevation: 0,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Раздельное туннелирование выключено на главном экране. Включите переключатель, чтобы применить эти правила.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
                if (!_splitEnabled) const SizedBox(height: 12),
                _buildPresetPicker(context),
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withOpacity(0.25),
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.layers_outlined,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            const Text(
                              'Режим туннелирования',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Выберите, как обрабатывать указанные домены и приложения',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Theme.of(context).hintColor),
                        ),
                        const SizedBox(height: 14),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'whitelist',
                              label: Text('Белый список'),
                            ),
                            ButtonSegment(
                              value: 'blacklist',
                              label: Text('Чёрный список'),
                            ),
                          ],
                          style: SegmentedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              vertical: 14,
                              horizontal: 18,
                            ),
                          ),
                          selected: {_splitMode},
                          onSelectionChanged: (selection) {
                            _changeSplitMode(selection.first);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildEntrySection(
                  context: context,
                  title: 'Домены',
                  description: isWide
                      ? 'Укажите домены, которые будут обрабатываться согласно выбранному режиму'
                      : 'Домены для фильтрации',
                  icon: Icons.language_outlined,
                  items: _activeSplitConfig.domains,
                  emptyPlaceholder: 'Доменов нет',
                  onAdd: () => _promptAddEntry(
                    title: 'Добавить домен',
                    hint: 'Например: example.com',
                    onSubmit: _addDomainEntry,
                  ),
                  onRemove: _removeDomainEntry,
                ),
                const SizedBox(height: 16),
                _buildEntrySection(
                  context: context,
                  title: 'Приложения',
                  description: Platform.isAndroid
                      ? 'Укажите Android-приложения по ID пакета'
                      : 'Укажите пути к EXE-файлам приложений',
                  icon: Icons.apps_outlined,
                  items: _activeSplitConfig.applications,
                  emptyPlaceholder: Platform.isAndroid
                      ? 'Приложений нет'
                      : 'Приложений нет',
                  onAdd: () => _promptAddEntry(
                    title: 'Добавить приложение',
                    hint: Platform.isAndroid
                        ? 'com.example.app'
                        : 'C:/Program Files/App/app.exe',
                    onSubmit: _addApplication,
                  ),
                  onRemove: _removeApplication,
                  extraContent: Platform.isAndroid
                      ? _buildAndroidAppActions(Theme.of(context))
                      : null,
                  labelBuilder: Platform.isAndroid
                      ? _describeApplicationEntry
                      : null,
                ),
                const SizedBox(height: 12),
                _buildPresetActionsBar(context),
                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPresetPicker(BuildContext context) {
    final theme = Theme.of(context);
    final presets = _splitPresets;
    final selectedValue = _hasActivePreset
        ? _activePresetName!
        : _noPresetValue;

    Widget buildTile({
      required String title,
      required String subtitle,
      required bool selected,
      IconData icon = Icons.bookmark_border,
    }) {
      return Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ),
          ),
          if (selected)
            Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
        ],
      );
    }

    return Center(
      child: PopupMenuButton<String>(
        initialValue: selectedValue,
        onSelected: _handlePresetSelection,
        offset: const Offset(0, 10),
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 280),
        color: theme.colorScheme.surfaceContainerHighest,
        itemBuilder: (ctx) {
          final items = <PopupMenuEntry<String>>[
            PopupMenuItem(
              value: _noPresetValue,
              child: buildTile(
                title: 'Без пресета',
                subtitle: 'Использовать текущие настройки',
                selected: selectedValue == _noPresetValue,
                icon: Icons.remove_circle_outline,
              ),
            ),
          ];
          if (presets.isNotEmpty) {
            items.add(const PopupMenuDivider());
            for (final preset in presets) {
              items.add(
                PopupMenuItem(
                  value: preset.name,
                  child: buildTile(
                    title: preset.name,
                    subtitle:
                        '${preset.domains.length} доменов, ${preset.applications.length} приложений',
                    selected: selectedValue == preset.name,
                    icon: Icons.bookmark_outline,
                  ),
                ),
              );
            }
          } else {
            items.add(
              const PopupMenuItem(enabled: false, child: Text('Пресетов нет')),
            );
          }
          return items;
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.2),
            ),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withOpacity(0.12),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Активный пресет',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bookmarks_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _activePresetLabel,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_down,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              if (_presetDirty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Есть несохранённые изменения',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPresetActionsBar(BuildContext context) {
    final theme = Theme.of(context);
    SplitTunnelPreset? activePreset;
    if (_activePresetName != null) {
      for (final preset in _splitPresets) {
        if (preset.name == _activePresetName) {
          activePreset = preset;
          break;
        }
      }
    }

    final buttons = <Widget>[];
    if (activePreset != null) {
      buttons.add(
        FilledButton.icon(
          onPressed: _presetDirty ? _overwriteActivePreset : null,
          icon: const Icon(Icons.save_outlined),
          label: const Text('Обновить пресет'),
        ),
      );
      buttons.add(
        OutlinedButton.icon(
          onPressed: () => _confirmDeletePreset(activePreset!),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Удалить'),
        ),
      );
    } else {
      buttons.add(
        FilledButton.icon(
          onPressed: _promptSavePreset,
          icon: const Icon(Icons.bookmark_add_outlined),
          label: const Text('Сохранить пресет'),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: buttons,
          ),
          if (_presetDirty && activePreset != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Пресет был изменён. Сохраните изменения.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusHero(BuildContext context, bool isWide) {
    final scheme = Theme.of(context).colorScheme;
    final isRunning = _isRunning;
    final gradient = isRunning
        ? [const Color(0xFFFF1B2D), const Color(0xFF51030F)]
        : [const Color(0xFF1A1B22), const Color(0xFF08090F)];
    final screenWidth = MediaQuery.of(context).size.width;
    final compact = screenWidth < 640;
    final isEnabled = _selectedProfile != null || _controller.text.trim().isNotEmpty;
    final canRefreshMetrics = _selectedProfile != null && !_pingInProgress;

    final statusText = Text(
      _status,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    );

    final topRow = SizedBox(
      height: 34,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(child: statusText),
          if (_generatedConfig != null)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                onPressed: () => _showConfigDialog(context),
                icon: const Icon(Icons.receipt_long, color: Colors.white),
              ),
            ),
        ],
      ),
    );

    final indicatorRow = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (_smartRouting)
          Icon(Icons.route_outlined, color: scheme.primary, size: 20),
        if (_splitEnabled)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Icon(Icons.call_split, color: scheme.primary, size: 20),
          ),
      ],
    );

    final buttonSize = compact ? 140.0 : 170.0;
    final connectButton = GestureDetector(
      onTap: isRunning ? _stop : (isEnabled ? _start : null),
      child: AnimatedBuilder(
        animation: _connectGlowController,
        builder: (context, child) {
          final rotation = _connectGlowController.value * 6.283185307179586;
          final showSpin = _isConnecting && !isRunning;
          final ringGradient = showSpin
              ? SweepGradient(
                  colors: [
                    scheme.primary,
                    scheme.primary.withOpacity(0.05),
                    scheme.primary,
                  ],
                  stops: const [0.0, 0.6, 1.0],
                  transform: GradientRotation(rotation),
                )
              : SweepGradient(
                  colors: [
                    scheme.primary.withOpacity(isRunning ? 0.6 : 0.12),
                    scheme.primary.withOpacity(0.02),
                    scheme.primary.withOpacity(isRunning ? 0.6 : 0.12),
                  ],
                );

          return AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: isEnabled || isRunning ? 1.0 : 0.4,
            child: Container(
              width: buttonSize,
              height: buttonSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: ringGradient,
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withOpacity(isRunning ? 0.35 : 0.12),
                    blurRadius: isRunning ? 28 : 18,
                    spreadRadius: isRunning ? 2 : 0,
                  ),
                ],
              ),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: buttonSize * 0.7,
                  height: buttonSize * 0.7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isRunning
                        ? scheme.primary
                        : const Color(0xFF171820),
                  ),
                  child: Icon(
                    isRunning ? Icons.stop_rounded : Icons.power_settings_new,
                    size: buttonSize * 0.35,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    final pingRow = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          'Ping: $_pingLabel',
          style: TextStyle(color: Colors.white.withOpacity(0.8)),
        ),
        const SizedBox(width: 6),
        IconButton(
          onPressed: canRefreshMetrics ? () => _refreshMetrics() : null,
          icon: Icon(
            _pingInProgress ? Icons.timelapse : Icons.refresh_outlined,
            color: Colors.white,
          ),
        ),
      ],
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: EdgeInsets.all(compact ? 16 : 28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          colors: gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(isRunning ? 0.25 : 0.1),
            blurRadius: 30,
            offset: const Offset(0, 20),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          topRow,
          const SizedBox(height: 6),
          indicatorRow,
          const SizedBox(height: 16),
          Center(child: connectButton),
          const SizedBox(height: 12),
          pingRow,
        ],
      ),
    );
  }

  Widget _buildProfileCard(BuildContext context) {
    final theme = Theme.of(context);
    if (!_hasEverAddedKey) {
      return Card(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.25),
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed: _showProfileDialog,
                child: const Text('\u0412\u0432\u0435\u0441\u0442\u0438 \u043a\u043b\u044e\u0447'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _pasteProfileFromClipboard,
                child: const Text('\u0412\u0441\u0442\u0430\u0432\u0438\u0442\u044c \u0438\u0437 \u0431\u0443\u0444\u0435\u0440\u0430 \u043e\u0431\u043c\u0435\u043d\u0430'),
              ),
            ],
          ),
        ),
      );
    }
    // ...existing code...
    final profileCard = Card(
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.25),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person_outline, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Профили подключения',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Добавить профиль',
                  onPressed: _showProfileDialog,
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 400,
              child: ProfileListView(
                profiles: _profiles,
                selectedProfile: _selectedProfile,
                subscriptionsRefreshToken: _subscriptionsRefreshToken,
                onSubscriptionsChanged: (hasSubs) {
                  if (!mounted) return;
                  setState(() => _hasSubscriptions = hasSubs);
                },
                onProfileSelected: (profile) {
                  if (!_isRunning) {
                    _selectCurrentProfile(profile);
                  }
                },
                onDeleteProfile: (profile) {
                  _removeProfileByName(profile.name);
                },
              ),
            ),
          ],
        ),
      ),
    );

    Widget splitCard = Card(
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.25),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.call_split, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Раздельное туннелирование',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Раздельное туннелирование',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 4),
                      Text('Разделяйте трафик по доменам и приложениям'),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _splitEnabled,
                  onChanged: (value) => _setSplitEnabled(value),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_splitEnabled) ...[
              DropdownButtonFormField<String>(
                initialValue: _hasActivePreset
                    ? _activePresetName
                    : _noPresetValue,
                decoration: const InputDecoration(labelText: 'Split preset'),
                items: [
                  DropdownMenuItem(
                    value: _noPresetValue,
                    child: Text(_presetDirty ? 'Custom *' : 'Custom'),
                  ),
                  ..._splitPresets.map(
                    (p) => DropdownMenuItem(value: p.name, child: Text(p.name)),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  _handlePresetSelection(value);
                },
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Smart Routing (Level 3)',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Automatically bypass Russian sites and networks while keeping foreign services via VPN.',
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _smartRouting,
                  onChanged: (value) {
                    setState(() => _smartRouting = value);
                    unawaited(_persistSplitState());
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            DpiEvasionWidget(
              manager: _dpiEvasionManager,
              config: _dpiEvasionConfig,
              serverHost: _currentLink?.host,
              serverPort: _currentLink?.port,
              onConfigChanged: _updateDpiConfig,
            ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        profileCard,
        const SizedBox(height: 16),
        splitCard,
        const SizedBox(height: 20),
        Divider(color: theme.colorScheme.onSurface.withOpacity(0.08)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            _buildInfoPill(
              context,
              Icons.history,
              'Log lines',
              _logLines.length.toString(),
            ),
            if (_parsed != null)
              _buildInfoPill(
                context,
                Icons.language,
                'Server',
                '${_parsed!.host}:${_parsed!.port}',
              ),
            if (_developerMode && _configFile != null)
              _buildInfoPill(
                context,
                Icons.folder_outlined,
                'Config Path',
                _configFile!.path,
                maxWidth: 240,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildLogPanel(BuildContext context) {
    final logText = _logLines.isEmpty
        ? 'Лог пуст. Подключитесь к VPN для просмотра сообщений.'
        : _logLines.join('\n');
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withOpacity(0.25),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal_rounded),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Лог подключения',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Очистить лог',
                  onPressed: _logLines.isEmpty
                      ? null
                      : () {
                          setState(() => _logLines.clear());
                        },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 280,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Scrollbar(
                    controller: _logScrollController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _logScrollController,
                      child: SelectableText(
                        logText,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntrySection({
    required BuildContext context,
    required String title,
    required String description,
    required IconData icon,
    required List<String> items,
    required String emptyPlaceholder,
    required Future<void> Function() onAdd,
    required void Function(String value) onRemove,
    Widget? extraContent,
    Widget? footer,
    String Function(String value)? labelBuilder,
  }) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.25),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
                  child: Icon(icon, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Добавить',
                  onPressed: () {
                    onAdd();
                  },
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (extraContent != null) ...[
              extraContent,
              const SizedBox(height: 16),
            ],
            if (items.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 20,
                  horizontal: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withOpacity(
                    0.25,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(emptyPlaceholder, style: theme.textTheme.bodySmall),
              )
            else
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: items.map((value) {
                  final label = labelBuilder?.call(value) ?? value;
                  return InputChip(
                    label: Text(label),
                    onDeleted: () => onRemove(value),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest
                        .withOpacity(0.35),
                    labelStyle: theme.textTheme.bodyMedium,
                  );
                }).toList(),
              ),
            if (footer != null) ...[const SizedBox(height: 12), footer],
          ],
        ),
      ),
    );
  }

  Future<void> _promptAddEntry({
    required String title,
    required String hint,
    required void Function(String value) onSubmit,
  }) async {
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => _SplitEntryDialog(title: title, hint: hint),
    );
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) return;
    onSubmit(normalized);
  }

  void _addDomainEntry(String value) {
    final normalized = _normalizeEntry(value);
    if (normalized.isEmpty) return;
    final current = _activeSplitConfig;
    final items = [...current.domains];
    if (items.contains(normalized)) return;
    items.add(normalized);
    _updateActiveSplitConfig(current.copyWith(domains: items));
  }

  void _removeDomainEntry(String value) {
    final normalized = _normalizeEntry(value);
    final current = _activeSplitConfig;
    final items = [...current.domains]..remove(normalized);
    _updateActiveSplitConfig(current.copyWith(domains: items));
  }

  void _addApplication(String value) {
    var normalized = _normalizeEntry(value);
    if (normalized.isEmpty) return;
    if (Platform.isAndroid) {
      const prefix = 'package:';
      if (normalized.startsWith(prefix)) {
        normalized = '$prefix${normalized.substring(prefix.length).trim()}';
      } else {
        normalized = '$prefix$normalized';
      }
    }
    final current = _activeSplitConfig;
    final apps = [...current.applications];
    if (apps.contains(normalized)) return;
    apps.add(normalized);
    _updateActiveSplitConfig(current.copyWith(applications: apps));
  }

  void _removeApplication(String value) {
    final normalized = _normalizeEntry(value);
    final current = _activeSplitConfig;
    final apps = [...current.applications]..remove(normalized);
    _updateActiveSplitConfig(current.copyWith(applications: apps));
  }

  String _normalizeEntry(String value) {
    var sanitized = value.trim();
    if (sanitized.length >= 2) {
      final first = sanitized[0];
      final last = sanitized[sanitized.length - 1];
      if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
        sanitized = sanitized.substring(1, sanitized.length - 1).trim();
      }
    }
    return sanitized;
  }

  Widget _buildInfoPill(
    BuildContext context,
    IconData icon,
    String title,
    String value, {
    double? maxWidth,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(16);
    final content = Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.1),
        borderRadius: radius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth ?? 220),
      child: onTap == null
          ? content
          : Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: radius,
                onTap: onTap,
                child: content,
              ),
            ),
    );
  }

  Future<void> _runConnectivityTests() async {
    if (_isConnectivityTesting) return;
    _connectivityTester.clearCache();
    _connectivityResults.clear();
    _connectivityLastRun = null;
    setState(() {
      _isConnectivityTesting = true;
      _cancelConnectivity = false;
      _connectivityCompleted = 0;
    });
    final results = await _connectivityTester.run(
      _connectivityTargets,
      onProgress: (completed, total) {
        if (!mounted) return;
        setState(() => _connectivityCompleted = completed);
      },
      isCancelled: () => _cancelConnectivity,
    );
    if (!mounted) return;
    setState(() {
      _connectivityResults
        ..clear()
        ..addAll(results);
      _isConnectivityTesting = false;
      _cancelConnectivity = false;
      _connectivityLastRun = DateTime.now();
    });
  }

  void _cancelConnectivityTests() {
    if (!_isConnectivityTesting) return;
    setState(() => _cancelConnectivity = true);
  }

  Future<void> _exportConnectivityResults() async {
    final payload = <String, dynamic>{
      for (final entry in _connectivityResults.entries)
        entry.key: entry.value.toJson(),
    };
    final jsonText = const JsonEncoder.withIndent('  ').convert(payload);
    await Clipboard.setData(ClipboardData(text: jsonText));
    if (!mounted) return;
    _showFastSnack('Results copied to clipboard');
  }

  Widget _buildConnectivityTestTab() {
    final theme = Theme.of(context);
    final total = _connectivityTargets.length;
    final completed = _connectivityCompleted;
    final running = _isConnectivityTesting;
    final results = _connectivityResults.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    Widget buildItem(String domain, ConnectivityTestResult result) {
      final color = switch (result.status) {
        'ok' => Colors.green,
        'timeout' => Colors.orange,
        _ => Colors.red,
      };
      final timeLabel = result.durationMs != null
          ? '${result.durationMs} мс'
          : '--';
      return Card(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.2),
        elevation: 0,
        child: ListTile(
          leading: Icon(Icons.circle, size: 12, color: color),
          title: Text(domain),
          subtitle: Text('${result.status} • $timeLabel'),
          trailing: result.httpStatus != null ? Text('HTTP ') : null,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Проверено: $completed / $total'),
              const SizedBox(width: 12),
              if (running)
                const Text(
                  'Выполняется...',
                  style: TextStyle(color: Colors.orange),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Massive Connectivity Test',
                style: theme.textTheme.titleLarge,
              ),
              FilledButton.icon(
                onPressed: running ? null : _runConnectivityTests,
                icon: Icon(running ? Icons.timer : Icons.play_arrow),
                label: Text(running ? 'Running...' : 'Start'),
              ),
              OutlinedButton.icon(
                onPressed: running
                    ? _cancelConnectivityTests
                    : _exportConnectivityResults,
                icon: Icon(
                  running ? Icons.stop_circle_outlined : Icons.download,
                ),
                label: Text(running ? 'Cancel' : 'Export'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Progress:  /  ( cached)', style: theme.textTheme.bodySmall),
          if (_connectivityLastRun != null)
            Text(
              'Last run: ',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: results.isEmpty
                ? Center(
                    child: Text(
                      'No results yet. Start testing to populate the list.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  )
                : ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final entry = results[index];
                      return buildItem(entry.key, entry.value);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SplitEntryDialog extends StatefulWidget {
  const _SplitEntryDialog({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  State<_SplitEntryDialog> createState() => _SplitEntryDialogState();
}

class _SplitEntryDialogState extends State<_SplitEntryDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            final value = _controller.text.trim();
            if (value.isEmpty) return;
            Navigator.of(context).pop(value);
          },
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}

class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Сохранить пресет'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Название пресета'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            final value = _controller.text.trim();
            if (value.isEmpty) return;
            Navigator.of(context).pop(value);
          },
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class _AndroidAppPickerSheet extends StatefulWidget {
  const _AndroidAppPickerSheet({required this.apps});

  final List<Application> apps;

  @override
  State<_AndroidAppPickerSheet> createState() => _AndroidAppPickerSheetState();
}

class _AndroidAppPickerSheetState extends State<_AndroidAppPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = _query.trim().toLowerCase();
    final filtered = normalizedQuery.isEmpty
        ? widget.apps
        : widget.apps.where((app) {
            final name = app.appName.toLowerCase();
            final package = app.packageName.toLowerCase();
            return name.contains(normalizedQuery) ||
                package.contains(normalizedQuery);
          }).toList();

    final height = MediaQuery.of(context).size.height * 0.7;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            const ListTile(title: Text('Выберите приложение')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Поиск',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('Приложений не найдено'))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final app = filtered[index];
                        return ListTile(
                          leading: const Icon(Icons.apps_outlined),
                          title: Text(app.appName),
                          subtitle: Text(app.packageName),
                          onTap: () =>
                              Navigator.of(context).pop(app.packageName),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
