import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:device_apps/device_apps.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
import 'services/update_service.dart';
import 'models/vpn_profile.dart';
import 'widgets/profile_list_view.dart';
import 'widgets/add_profile_dialog.dart';
import 'widgets/dpi_evasion_widget.dart';
import 'widgets/animated_emoji.dart';
import 'widgets/neural_background.dart';
import 'widgets/loading_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru_RU', null);
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    final windowOptions = WindowOptions(
      size: Platform.isWindows ? Size(420, 720) : Size(1100, 760),
      minimumSize: Platform.isWindows ? Size(320, 560) : Size(900, 640),
      center: true,
      backgroundColor: Colors.transparent,
      titleBarStyle: Platform.isWindows
          ? TitleBarStyle.hidden
          : TitleBarStyle.normal,
      title: 'neuravpn',
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
      title: 'neuravpn',
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
      scrollBehavior: const _AppScrollBehavior(),
      home: const VlessHomePage(),
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };
}

enum _WindowsView { connection, splitTunneling, settings }

class VlessHomePage extends StatefulWidget {
  const VlessHomePage({super.key});

  @override
  State<VlessHomePage> createState() => _VlessHomePageState();
}

class _VlessHomePageState extends State<VlessHomePage>
    with TrayListener, WindowListener, SingleTickerProviderStateMixin {
  static const String _updateOwner = 'Asort97';
  static const String _updateRepo = 'neuravpn-client';
  static const String _updateDismissedTagKey = 'update_dismissed_tag';
  static const String _updateLastCheckKey = 'update_last_check_ms';

  final TextEditingController _controller = TextEditingController();
  String _status = '\u041e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e';
  _WindowsView _windowsView = _WindowsView.connection;
  bool _showLoadingScreen = Platform.isWindows;
  late final PageController _windowsPageController;
  bool _singBoxWatchdogStarted = false;
  static const List<_WindowsView> _windowsViewOrder = [
    _WindowsView.connection,
    _WindowsView.splitTunneling,
    _WindowsView.settings,
  ];
  static const Color _neuraBlack = Color(0xFF0A0A0A);
  static const Color _neuraCardColor = Color(0xFF1A1A1A);
  static const Color _neuraSurface = Color(0xFF2A2A2A);
  static const Color _neuraRed = Color(0xFFEF4444);
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
  Timer? _logFlushTimer;
  final List<String> _pendingLogLines = <String>[];
  bool _trafficFetchInProgress = false;
  final List<double> _trafficHistory = <double>[];
  StreamSubscription<int>? _trafficSub;
  final TrayManager _trayManager = TrayManager.instance;
  bool _trayInitialized = false;
  bool _isExitingApp = false;
  bool _isConnecting = false;
  bool _isDisconnecting = false;
  bool _connectButtonHovered = false;
  bool _hasSubscriptions = false;
  bool _trayPopupMode = false;
  OverlayEntry? _trayOverlayEntry;
  Rect? _trayRestoreBounds;
  bool _trayRestoreWasVisible = false;
  late final AnimationController _connectGlowController;
  late final Animation<double> _connectGlowAnimation;
  bool _androidAppsLoaded = false;
  bool _androidAppsLoading = false;
  String? _androidAppLoadError;
  List<Application> _androidInstalledApps = const <Application>[];
  Map<String, String> _androidAppLabels = {};
  List<_WindowsAppEntry> _windowsInstalledApps = <_WindowsAppEntry>[];
  Map<String, String> _windowsAppLabels = {};
  Map<String, String> _windowsAppIcons = {};
  bool _windowsAppsLoaded = false;
  bool _windowsAppsLoading = false;
  Completer<void>? _windowsAppsLoadCompleter;
  String? _windowsAppLoadError;
  static const String _splitConfigPrefsKey = 'split_tunnel_state_v2';
  static const String _legacySplitConfigKey = 'split_tunnel_config_v1';
  static const String _trayShowKey = 'show';
  static const String _trayConnectKey = 'connect';
  static const String _trayDisconnectKey = 'disconnect';
  static const String _trayExitKey = 'exit';
  static const String _noPresetValue = '__none__';
  static const String _splitToggleKey = 'split_tunnel_enabled';
  static const String _smartRoutingKey = 'smart_routing_enabled';
  static const String _hasEverAddedKeyKey = 'has_added_key';
  static const Map<String, List<String>> _domainSubdomainsMap = {
    'youtube.com': [
      'youtube.com',
      'youtubekids.com',
      'youtube-nocookie.com',
      'youtubeembeddedplayer.googleapis.com',
      'youtubei.googleapis.com',
      'youtu.be',
      'yt-video-upload.l.google.com',
      'ytimg.com',
      'ytimg.l.google.com',
      'yt3.ggpht.com',
      'yt4.ggpht.com',
      'yt3.googleusercontent.com',
      'googlevideo.com',
      'jnn-pa.googleapis.com',
      'wide-youtube.l.google.com',
      'youtube-ui.l.google.com',
    ],
    'discord.com': [
      'discord.com',
      'discord.app',
      'discord.co',
      'discord.design',
      'discord.dev',
      'discord.gift',
      'discord.gifts',
      'discord.gg',
      'discord.media',
      'discord.new',
      'discord.store',
      'discord.status',
      'discordactivities.com',
      'discordapp.com',
      'discordapp.net',
      'discordcdn.com',
      'discordmerch.com',
      'discordpartygames.com',
      'discordsays.com',
      'discordsez.com',
      'discordstatus.com',
    ],
  };
  int? _pingMs;
  bool _pingInProgress = false;
  bool _splitEnabled = false;
  bool _showPresetList = false;
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
  static const String _dpiFragmentationKey = 'dpi_fragmentation_enabled';
  static const String _dpiTlsFragmentKey = 'dpi_tls_fragment_enabled';
  static const String _dpiTlsRecordFragmentKey = 'dpi_tls_record_fragment_enabled';
  static const String _dpiTrafficNoiseKey = 'dpi_traffic_noise_enabled';
  static const String _dpiMultiplexPaddingKey = 'dpi_multiplex_padding_enabled';
  static const String _dpiTcpWindowClampKey = 'dpi_tcp_window_clamp_enabled';
  static const String _dpiSniRandomizationKey = 'dpi_sni_randomization_enabled';
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
  String _appVersion = '';
  UpdateCheckResult? _updateResult;
  bool _checkingUpdates = false;

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
      ? 'РР·РјРµСЂРµРЅРёРµ...'
      : (_pingMs != null ? '$_pingMs мс' : '--');
  SplitTunnelConfig get _activeSplitConfig =>
      _splitConfigs[_splitMode] ?? _splitConfigs['all']!;
  SplitTunnelConfig get _effectiveSplitConfig =>
      _splitEnabled ? _activeSplitConfig : SplitTunnelConfig(mode: 'all');
  
  /// Раскрывает домены с предопределенными поддоменами (youtube.com -> все поддомены YouTube)
  List<String> _expandDomainsWithSubdomains(List<String> domains) {
    final expanded = <String>[];
    for (final domain in domains) {
      final subdomains = _domainSubdomainsMap[domain];
      if (subdomains != null) {
        // Для известных доменов (youtube.com, discord.com) добавляем все поддомены
        expanded.addAll(subdomains);
      } else {
        // Для остальных доменов добавляем как есть
        expanded.add(domain);
      }
    }
    return expanded;
  }
  
  SplitTunnelConfig get _configForConnection {
    final effective = _effectiveSplitConfig;
    // Раскрываем домены с поддоменами под капотом
    final expandedDomains = _expandDomainsWithSubdomains(effective.domains);
    return effective.copyWith(
      domains: expandedDomains,
      smartRouting: _smartRouting,
      smartDomains: _smartRouteEngine.exportLegacyRuleEntries(),
    );
  }

  int _windowsViewIndex(_WindowsView view) {
    return _windowsViewOrder.indexOf(view);
  }

  _WindowsView _windowsViewAt(int index) {
    if (index < 0 || index >= _windowsViewOrder.length) {
      return _WindowsView.connection;
    }
    return _windowsViewOrder[index];
  }
  @override
  void initState() {
    super.initState();
    _windowsPageController = PageController(
      initialPage: _windowsViewIndex(_windowsView),
    );
    _connectGlowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _connectGlowAnimation = CurvedAnimation(
      parent: _connectGlowController,
      curve: Curves.easeInOutCubic,
    );
    _updateConnectGlowTicker();
    _loadInitialData();
    unawaited(_initVersionAndUpdates());
    _checkWintun();
    if (_isDesktopPlatform) {
      windowManager.addListener(this);
      _trayManager.addListener(this);
      unawaited(_initDesktopShell());
      if (Platform.isWindows) {
        unawaited(_startSingBoxWatchdog());
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_fitWindowToDisplay());
        });
      }
    }
    if (Platform.isAndroid) {
      unawaited(_loadAndroidApps());
    }
  }

  Future<void> _checkWintun() async {
    final available = await _singBoxController.isWintunAvailable();
    if (!available && mounted) {
      _showFastSnack('wintun.dll \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d');
    }
  }

  Future<void> _initVersionAndUpdates() async {
    if (!Platform.isWindows) return;
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion = info.version;
      });
    } catch (_) {
      // ignore
    }
    await _maybeCheckForUpdates();
  }

  Future<void> _maybeCheckForUpdates({bool manual = false}) async {
    if (!Platform.isWindows) return;
    if (_updateOwner == 'YOUR_GITHUB_OWNER' ||
        _updateRepo == 'YOUR_GITHUB_REPO') {
      return;
    }
    if (_checkingUpdates) return;
    _checkingUpdates = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final lastMs = prefs.getInt(_updateLastCheckKey);
      final last = lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs);
      final shouldSkip = !manual &&
          last != null &&
          now.difference(last) < const Duration(hours: 12);
      if (shouldSkip) return;
      await prefs.setInt(_updateLastCheckKey, now.millisecondsSinceEpoch);

      final service = GithubUpdateService();
      final latest = await service.fetchLatestRelease(
        _updateOwner,
        _updateRepo,
      );
      if (latest == null) {
        if (manual && mounted) {
          _showFastSnack('\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043f\u0440\u043e\u0432\u0435\u0440\u0438\u0442\u044c \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u044f');
        }
        return;
      }

      final current = _appVersion.isNotEmpty ? _appVersion : '0.0.0';
      final result = service.compareVersions(
        currentVersion: current,
        latest: latest,
      );
      if (result == null) return;

      if (!mounted) return;
      setState(() => _updateResult = result);

      if (!result.isUpdateAvailable) {
        if (manual) {
          _showFastSnack('\u0423 \u0432\u0430\u0441 \u0443\u0436\u0435 \u043f\u043e\u0441\u043b\u0435\u0434\u043d\u044f\u044f \u0432\u0435\u0440\u0441\u0438\u044f');
        }
        return;
      }

      final dismissed = prefs.getString(_updateDismissedTagKey);
      if (!manual && dismissed == result.latestTag) {
        return;
      }
      _showUpdateDialog(result);
    } finally {
      _checkingUpdates = false;
    }
  }

  void _showUpdateDialog(UpdateCheckResult result) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _neuraCardColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '\u0414\u043e\u0441\u0442\u0443\u043f\u043d\u043e \u043e\u0431\u043d\u043e\u0432\u043b\u0435\u043d\u0438\u0435',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '\u0412\u0435\u0440\u0441\u0438\u044f ${result.latestVersion} \u0434\u043e\u0441\u0442\u0443\u043f\u043d\u0430 (\u0443 \u0432\u0430\u0441 ${result.currentVersion}).',
                style: TextStyle(color: Colors.white.withOpacity(0.75)),
              ),
              if (result.releaseNotes.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _neuraSurface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withOpacity(0.06)),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      result.releaseNotes,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: () async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString(
                        _updateDismissedTagKey,
                        result.latestTag,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                    child: const Text('\u041f\u043e\u0437\u0436\u0435'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      _openUrl(result.releaseUrl.toString());
                      Navigator.of(ctx).pop();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: _neuraRed,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('\u041e\u0442\u043a\u0440\u044b\u0442\u044c \u0440\u0435\u043b\u0438\u0437'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    if (!Platform.isWindows) return;
    try {
      await Process.start('cmd', ['/c', 'start', '', url], runInShell: true);
    } catch (_) {
      // ignore
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

  Future<void> _loadWindowsApps({bool force = false}) async {
    if (!Platform.isWindows) return;
    if (_windowsAppsLoading) {
      await (_windowsAppsLoadCompleter?.future ?? Future.value());
      return;
    }
    if (_windowsAppsLoaded && !force) return;
    if (!mounted) return;
    setState(() {
      _windowsAppsLoading = true;
      if (force) {
        _windowsAppLoadError = null;
      }
    });
    _windowsAppsLoadCompleter = Completer<void>();

    final supportDir = await getApplicationSupportDirectory();
    final iconDir = Directory('${supportDir.path}/app_icons');
    if (!iconDir.existsSync()) {
      iconDir.createSync(recursive: true);
    }
    final safeIconDir = iconDir.path.replaceAll("'", "''");
    final script = r'''
$paths = @(
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
  "$env:AppData\Microsoft\Windows\Start Menu\Programs"
)
$iconDir = ''' + "'$safeIconDir'\n" + r'''
New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
$iconEnabled = $true
try {
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
  $iconEnabled = $false
}
$shell = New-Object -ComObject WScript.Shell
$items = foreach ($base in $paths) {
  if (Test-Path $base) {
    Get-ChildItem -Path $base -Recurse -Filter *.lnk | ForEach-Object {
      try {
        $sc = $shell.CreateShortcut($_.FullName)
        $target = $sc.TargetPath
        $args = $sc.Arguments
        # Handle launcher-style shortcuts: any target with --processStart App.exe args
        $resolvedFromArgs = $null
        if ($args) {
          $pattern = '--processStart(?:AndWait)?\\s+"?([^"\\s]+\\.exe)"?'
          $m = [regex]::Match($args, $pattern, "IgnoreCase")
          if ($m.Success) {
            $exeName = $m.Groups[1].Value
            $searchRoots = @()
            if ($target) {
              $searchRoots += (Split-Path $target -Parent)
            }
            $searchRoots += (Split-Path $_.FullName -Parent)
            foreach ($root in $searchRoots | Select-Object -Unique) {
              if ($root -and (Test-Path $root)) {
                $candidate = Get-ChildItem -Path $root -Filter $exeName -File -Recurse -ErrorAction SilentlyContinue |
                  Select-Object -First 1 -ExpandProperty FullName
                if ($candidate -and (Test-Path $candidate)) {
                  $resolvedFromArgs = $candidate
                  break
                }
              }
            }
          }
        }
        if ($resolvedFromArgs) {
          $target = $resolvedFromArgs
        }
        $exeTargets = @()
        if ($target -and (Test-Path $target) -and $target.ToLower().EndsWith(".exe")) {
          $exeTargets += $target
          # Generic fallback for launcher/updater wrappers:
          # if processStart arg exists but exact target wasn't resolved, include a descendant exe too.
          if ($args -and -not $resolvedFromArgs) {
            $searchRoot = Split-Path $target -Parent
            if ($searchRoot -and (Test-Path $searchRoot)) {
              $childExe = Get-ChildItem -Path $searchRoot -Filter *.exe -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $target } | Select-Object -First 1
              if ($childExe) { $exeTargets += $childExe.FullName }
            }
          }
        }
        foreach ($exe in $exeTargets | Select-Object -Unique) {
          $bytes = [System.Text.Encoding]::UTF8.GetBytes($exe)
          $sha1 = New-Object System.Security.Cryptography.SHA1Managed
          $hash = [System.BitConverter]::ToString($sha1.ComputeHash($bytes)).Replace('-', '')
          $iconPath = Join-Path $iconDir ($hash + ".png")
          if ($iconEnabled -and !(Test-Path $iconPath)) {
            try {
              $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
              if ($icon -ne $null) {
                $bmp = $icon.ToBitmap()
                $bmp.Save($iconPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                $icon.Dispose()
              }
            } catch {
              # ignore icon extraction errors
            }
          }
          $iconOut = ''
          if (Test-Path $iconPath) { $iconOut = $iconPath }
          [PSCustomObject]@{ name = $_.BaseName; path = $exe; icon = $iconOut }
        }
      } catch {}
    }
  }
}

# Fallback: registry-installed apps (covers cases where Start Menu shortcuts are missing)
$regPaths = @(
  "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$regItems = foreach ($rp in $regPaths) {
  try {
    Get-ItemProperty $rp -ErrorAction SilentlyContinue | ForEach-Object {
      $name = $_.DisplayName
      if (-not $name) { return }
      $exe = $null
      $icon = $_.DisplayIcon
      if ($icon) {
        # DisplayIcon can be: "C:\Path\App.exe,0"
        $candidate = $icon.Split(',')[0].Trim('"')
        if ($candidate -and (Test-Path $candidate) -and $candidate.ToLower().EndsWith(".exe")) {
          $exe = $candidate
        }
      }
      if (-not $exe) {
        $uninstall = $_.UninstallString
        if ($uninstall) {
          # Try to extract first quoted path, or first token
          $m = [regex]::Match($uninstall, '"([^"]+\.exe)"')
          if ($m.Success) {
            $candidate = $m.Groups[1].Value
            if ($candidate -and (Test-Path $candidate)) { $exe = $candidate }
          } else {
            $candidate = $uninstall.Split(' ')[0].Trim('"')
            if ($candidate -and (Test-Path $candidate) -and $candidate.ToLower().EndsWith(".exe")) {
              $exe = $candidate
            }
          }
        }
      }
      if ($exe) {
        [PSCustomObject]@{ name = $name; path = $exe; icon = '' }
      }
    }
  } catch {}
}

($items + $regItems) | Where-Object { $_ -ne $null } | Sort-Object -Property path -Unique | ConvertTo-Json -Compress
''';

    Directory? tempDir;
    File? scriptFile;
    try {
      tempDir = await Directory.systemTemp.createTemp('neura_apps_');
      scriptFile = File('${tempDir.path}/apps.ps1');
      await scriptFile.writeAsString(script);

      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptFile.path],
      );
      if (result.exitCode != 0) {
        throw Exception(result.stderr?.toString().trim().isNotEmpty == true
            ? result.stderr.toString().trim()
            : 'Failed to enumerate Windows apps');
      }

      final stdout = (result.stdout ?? '').toString().trim();
      final apps = <_WindowsAppEntry>[];
      final icons = <String, String>{};
      if (stdout.isNotEmpty && stdout != 'null') {
        final decoded = jsonDecode(stdout);
        final rows = decoded is List ? decoded : [decoded];
        for (final row in rows) {
          if (row is Map) {
            final name = row['name']?.toString().trim() ?? '';
            final path = row['path']?.toString().trim() ?? '';
            final icon = row['icon']?.toString().trim() ?? '';
            if (name.isNotEmpty && path.isNotEmpty) {
              apps.add(_WindowsAppEntry(name: name, path: path, iconPath: icon));
              if (icon.isNotEmpty && File(icon).existsSync()) {
                icons[path] = icon;
              }
            }
          }
        }
      }

      apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _windowsInstalledApps = apps;
        _windowsAppLabels = {for (final app in apps) app.path: app.name};
        _windowsAppIcons = icons;
        _windowsAppsLoaded = true;
        _windowsAppsLoading = false;
        _windowsAppLoadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _windowsAppsLoading = false;
        _windowsAppLoadError = e.toString();
      });
    } finally {
      _windowsAppsLoadCompleter?.complete();
      _windowsAppsLoadCompleter = null;
      try {
        if (scriptFile != null && await scriptFile.exists()) {
          await scriptFile.delete();
        }
      } catch (_) {}
      try {
        if (tempDir != null && await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<void> _showWindowsAppPicker() async {
    if (!Platform.isWindows) return;
    // Avoid nuking a previously-good cache on a transient PowerShell failure.
    if (!_windowsAppsLoaded || _windowsInstalledApps.isEmpty) {
      await _loadWindowsApps(force: true);
    } else {
      await _loadWindowsApps();
    }
    if (!mounted) return;
    final apps = _windowsInstalledApps;
    final path = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => _WindowsAppPickerSheet(
        apps: apps,
        errorMessage: _windowsAppLoadError,
      ),
    );
    if (path == null || path.isEmpty) return;
    _addApplication(path);
  }

  Widget _buildWindowsAppActions(ThemeData theme) {
    final canPick = _windowsAppsLoaded || !_windowsAppsLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            TextButton.icon(
              onPressed: canPick ? _showWindowsAppPicker : null,
              icon: const Icon(Icons.apps_outlined),
              label: const Text('Выбрать приложение из списка'),
            ),
            TextButton.icon(
              onPressed: _windowsAppsLoading
                  ? null
                  : () => _loadWindowsApps(force: true),
              icon: const Icon(Icons.refresh_outlined),
              label: const Text('Обновить список'),
            ),
            if (_windowsAppsLoading)
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
        if (_windowsAppLoadError != null)
          Text(
            'Не удалось загрузить приложения: $_windowsAppLoadError',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          )
        else
          Text(
            'Список приложений готов. Можно выбрать из списка или ввести путь вручную.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
      ],
    );
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
    final windowsLabel = _windowsAppLabels[value];
    if (windowsLabel != null && windowsLabel.isNotEmpty) {
      return windowsLabel;
    }
    if (value.toLowerCase().endsWith('.exe')) {
      final fallbackName = path.basenameWithoutExtension(value);
      if (fallbackName.isNotEmpty) {
        return fallbackName;
      }
    }
    return value;
  }

  Widget _buildWindowsAppIcon(String value, {double size = 20}) {
    if (!Platform.isWindows) {
      return Icon(Icons.apps_outlined, size: size, color: _neuraRed);
    }
    final iconPath = _windowsAppIcons[value];
    if (iconPath != null && iconPath.isNotEmpty) {
      final file = File(iconPath);
      if (file.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.file(
            file,
            width: size,
            height: size,
            fit: BoxFit.cover,
          ),
        );
      }
    }
    return Icon(Icons.apps_outlined, size: size, color: _neuraRed);
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

  void _dismissLoadingScreen() {
    if (!_showLoadingScreen) return;
    if (!mounted) return;
    setState(() => _showLoadingScreen = false);
  }

  String _tabLabelForView(_WindowsView view) {
    switch (view) {
      case _WindowsView.connection:
        return 'Подключение';
      case _WindowsView.splitTunneling:
        return 'Раздельное туннелирование';
      case _WindowsView.settings:
        return 'Настройки';
    }
  }

  void _updateConnectGlowTicker() {
    final shouldAnimate = _isConnecting || _isRunning;
    if (shouldAnimate) {
      if (!_connectGlowController.isAnimating) {
        _connectGlowController.repeat();
      }
    } else {
      if (_connectGlowController.isAnimating) {
        _connectGlowController.stop();
      }
      _connectGlowController.value = 0;
    }
  }

  void _startTrafficMonitor() {
    if (_trafficSub != null) return;
    if (_trafficHistory.isEmpty) {
      _trafficHistory.addAll(List<double>.filled(20, 0));
    }
    unawaited(_singBoxController.startTrafficStream());
    _trafficSub = _singBoxController.trafficStream.listen((sample) {
      if (!mounted) return;
      setState(() {
        _trafficHistory.add(sample.toDouble());
        if (_trafficHistory.length > 80) {
          _trafficHistory.removeAt(0);
        }
      });
    });
  }

  Future<void> _stopTrafficMonitor() async {
    _trafficSub?.cancel();
    _trafficSub = null;
    _trafficFetchInProgress = false;
    _trafficHistory.clear();
    await _singBoxController.stopTrafficStream();
    // Даем немного времени для полной остановки
    await Future.delayed(const Duration(milliseconds: 200));
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
    final dpiBase =
        dpiAggressive ? DpiEvasionConfig.aggressive : DpiEvasionConfig.balanced;
    final dpiFragmentation =
        prefs.getBool(_dpiFragmentationKey) ?? dpiBase.enableFragmentation;
    final dpiTlsFragment =
        prefs.getBool(_dpiTlsFragmentKey) ?? dpiBase.enableTlsFragment;
    final dpiTlsRecordFragment = prefs.getBool(_dpiTlsRecordFragmentKey) ??
        dpiBase.enableTlsRecordFragment;
    final dpiTrafficNoise =
        prefs.getBool(_dpiTrafficNoiseKey) ?? dpiBase.enableTrafficNoise;
    final dpiMultiplexPadding = prefs.getBool(_dpiMultiplexPaddingKey) ??
        dpiBase.enableMultiplexPadding;
    final dpiTcpWindowClamp =
        prefs.getBool(_dpiTcpWindowClampKey) ?? dpiBase.enableTcpWindowClamp;
    final dpiSniRandomization = prefs.getBool(_dpiSniRandomizationKey) ??
        dpiBase.enableSniCaseRandomization;

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

    final repository = SubscriptionRepository();
    final subscriptions = await repository.getAllSubscriptions();
    _hasSubscriptions = subscriptions.isNotEmpty;

    if (profiles.isEmpty && subscriptions.isEmpty) {
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
    if (selected == null && subscriptions.isNotEmpty) {
      final firstSub = subscriptions.first;
      final uri = firstSub.selectedProfile ??
          (firstSub.profiles.isNotEmpty ? firstSub.profiles.first : null);
      if (uri != null && uri.isNotEmpty) {
        final autoName = _deriveProfileNameFromUri(uri);
        selected = VpnProfile(
          name: autoName.isEmpty ? _deriveSubscriptionNameFromUrl(firstSub.url) : autoName,
          uri: uri,
        );
      }
    }

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
      _dpiEvasionConfig = dpiBase.copyWith(
        enableFragmentation: dpiFragmentation,
        enableTlsFragment: dpiTlsFragment,
        enableTlsRecordFragment: dpiTlsRecordFragment,
        enableTrafficNoise: dpiTrafficNoise,
        enableMultiplexPadding: dpiMultiplexPadding,
        enableTcpWindowClamp: dpiTcpWindowClamp,
        enableSniCaseRandomization: dpiSniRandomization,
      );
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

  Future<void> _setDeveloperMode(bool enabled) async {
    if (_developerMode == enabled) return;
    setState(() => _developerMode = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('developer_mode', enabled);
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

  Future<void> _setSmartRouting(bool enabled) async {
    if (_smartRouting == enabled) return;
    setState(() => _smartRouting = enabled);
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

  Future<void> _startSingBoxWatchdog() async {
    if (_singBoxWatchdogStarted || !Platform.isWindows) return;
    _singBoxWatchdogStarted = true;
    final parentPid = pid;
    final command =
        '\$parent=$parentPid;'
        'while (Get-Process -Id \$parent -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 500 };'
        'Start-Sleep -Milliseconds 200;'
        "Stop-Process -Name 'sing-box' -Force -ErrorAction SilentlyContinue";
    try {
      await Process.start(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      // Ignore: best-effort watchdog for forced app termination.
    }
  }

  Future<void> _fitWindowToDisplay() async {
    const targetWidth = 420.0;
    const targetHeight = 720.0;
    final current = await windowManager.getSize();
    final nextWidth = current.width > targetWidth ? targetWidth : current.width;
    final nextHeight =
        current.height > targetHeight ? targetHeight : current.height;
      await windowManager.setSize(Size(nextWidth, nextHeight));
      await windowManager.setMinimumSize(const Size(420, 720));
      await windowManager.setMaximumSize(const Size(420, 720));
      await windowManager.setResizable(false);
      await windowManager.center();
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
  }

  Future<void> _setupTrayIcon() async {
    if (_trayInitialized) return;
    final iconPath = await _prepareTrayIconFile();
    await _trayManager.setIcon(iconPath);
    await _trayManager.setToolTip('neuravpn');
    final menu = Menu(
      items: [
        MenuItem(key: _trayShowKey, label: 'Показать окно'),
        MenuItem.separator(),
        MenuItem(key: _trayExitKey, label: 'Выход'),
      ],
    );
    await _trayManager.setContextMenu(menu);
    await _updateTrayMenu();
    _trayInitialized = true;
  }

  Future<void> _updateTrayMenu() async {
    if (!_isDesktopPlatform) return;

    final canConnect =
        !_isConnecting && !_isRunning && _controller.text.trim().isNotEmpty;
    final canDisconnect = !_isConnecting && _isRunning;

    final statusLabel = _isConnecting
        ? 'Статус: подключается…'
        : _isRunning
            ? 'Статус: подключено'
            : 'Статус: не подключено';

    final actionItem = canConnect
        ? MenuItem(key: _trayConnectKey, label: 'Подключиться')
        : canDisconnect
            ? MenuItem(key: _trayDisconnectKey, label: 'Отключиться')
            : MenuItem(
                label: _isConnecting
                    ? 'Подключается…'
                    : _controller.text.trim().isEmpty
                        ? 'Нет профиля для подключения'
                        : _isRunning
                            ? 'Подключено'
                            : 'Готово',
                disabled: true,
              );

    final menu = Menu(
      items: [
        MenuItem(label: statusLabel, disabled: true),
        MenuItem.separator(),
        actionItem,
        MenuItem.separator(),
        MenuItem(key: _trayShowKey, label: 'Показать окно'),
        MenuItem.separator(),
        MenuItem(key: _trayExitKey, label: 'Выход'),
      ],
    );

    await _trayManager.setContextMenu(menu);
  }

  Future<String> _prepareTrayIconFile() async {
    final tmpDir = await getTemporaryDirectory();
    const primaryAssetKey = 'windows/runner/resources/hc_icon.ico';
    const fallbackAssetKey = 'windows/runner/resources/app_icon.ico';
    ByteData icoData;
    try {
      icoData = await rootBundle.load(primaryAssetKey);
    } catch (_) {
      icoData = await rootBundle.load(fallbackAssetKey);
    }
    final icoFile = File('${tmpDir.path}/neuravpn_tray.ico');
    await icoFile.writeAsBytes(icoData.buffer.asUint8List(), flush: true);
    return icoFile.path;
  }

  Future<void> _hideToTray({bool showHint = false}) async {
    if (!_isDesktopPlatform) return;
    await windowManager.hide();
    if (showHint && mounted) {
      _showFastSnack('Свернуто в трей');
    }
  }

  String get _trayStatusLabel {
    if (_isConnecting) return 'Статус: подключается…';
    if (_isRunning) return 'Статус: подключено';
    return 'Статус: не подключено';
  }

  Future<void> _hideTrayPopup({bool restoreMainWindow = false}) async {
    if (!_isDesktopPlatform) return;

    _trayOverlayEntry?.remove();
    _trayOverlayEntry = null;

    if (!_trayPopupMode) return;

    setState(() => _trayPopupMode = false);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);

    await windowManager.hide();

    if (_trayRestoreWasVisible) {
      final bounds = _trayRestoreBounds;
      if (bounds != null) {
        await windowManager.setSize(bounds.size);
        await windowManager.setPosition(bounds.topLeft);
      } else if (Platform.isWindows) {
        await _fitWindowToDisplay();
      }
      await windowManager.show();
      await windowManager.focus();
    } else if (Platform.isWindows) {
      unawaited(_fitWindowToDisplay());
    }

    _trayRestoreBounds = null;
    _trayRestoreWasVisible = false;
  }

  Future<void> _showTrayMenu() async {
    if (!_isDesktopPlatform) return;

    final isVisible = await windowManager.isVisible();
    _trayRestoreWasVisible = isVisible;
    _trayRestoreBounds = isVisible ? await windowManager.getBounds() : null;

    if (isVisible) {
      await windowManager.hide();
    }

    final cursor = _getCursorPosition();
    const menuWidth = 220.0;
    const menuHeight = 168.0;
    final x = math.max(0.0, cursor.dx - menuWidth + 12);
    final y = math.max(0.0, cursor.dy - menuHeight - 8.0);

    setState(() => _trayPopupMode = true);

    await windowManager.setSize(const Size(menuWidth, menuHeight));
    await windowManager.setPosition(Offset(x, y));
    await windowManager.setSkipTaskbar(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();
  }

  Offset _getCursorPosition() {
    return Offset.zero;
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
    _stopTrafficMonitor();
    await _dpiEvasionManager.stopNativeInjector();
    await _singBoxController.forceTerminate();
    unawaited(_singBoxController.dispose());
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
      case _trayConnectKey:
        unawaited(() async {
          await _start();
          await _updateTrayMenu();
        }());
        break;
      case _trayDisconnectKey:
        unawaited(() async {
          await _stop();
          await _updateTrayMenu();
        }());
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
    unawaited(_hideToTray());
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
        throw 'Подписка не вернула профили';
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
          const SnackBar(content: Text('Подписка добавлена')),
        );
        await _clearAllProfilesForSubscriptionMode();
        await _reloadSubscriptions();

        if (!mounted) return;
        final uri = profiles.first;
        final autoName = _deriveProfileNameFromUri(uri);
        final profile = VpnProfile(
          name: autoName.isEmpty ? _deriveSubscriptionNameFromUrl(url) : autoName,
          uri: uri,
        );
        await _selectCurrentProfile(profile);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось добавить: ссылка уже есть')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
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
    if (normalized.contains('попытка') || normalized.contains('attempt')) {
      return value;
    }
    if (normalized.contains('connect')) {
      return '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0430\u0435\u0442\u0441\u044f';
    }
    if (normalized.contains('connected') || normalized.contains('running')) {
      return '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u043e';
    }
    if (normalized.contains('disconnect')) {
      return '\u041e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e';
    }
    return value;
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
    return host.isNotEmpty ? host : 'Подписка';
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
    // Защита от спама - проверяем, не идёт ли уже подключение или отключение
    if (_isConnecting || _isDisconnecting) return;
    
    if (_isRunning) {
      await _stop();
      // Проверяем что действительно отключилось
      await _ensureDisconnected();
      // Даем дополнительное время для полной очистки ресурсов
      await Future.delayed(const Duration(seconds: 1));
    }

    setState(() {
      _status = '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0430\u0435\u0442\u0441\u044f';
      _isConnecting = true;
      _logLines.clear();
    });
    unawaited(_updateTrayMenu());
    _updateConnectGlowTicker();
    _startTrafficMonitor();
    final result = await _singBoxController.connect(
      rawUri: _controller.text,
      splitConfig: _configForConnection,
      developerMode: _developerMode,
      smartRouteEngine: _smartRouteEngine,
      dpiEvasionConfig: _dpiEvasionConfig,
      onStatus: (value) {
        if (!mounted) return;
        setState(() => _status = _mapStatus(value));
        unawaited(_updateTrayMenu());
      },
      onLog: (line) {
        _appendLogs([line]);
      },
    );

    if (!result.success) {
      if (!mounted) return;
      if (result.requiresAdmin && Platform.isWindows) {
        _showFastSnack('Запустите приложение от имени администратора');
        setState(() {
          _status = '\u041e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e';
          _isConnecting = false;
        });
        unawaited(_updateTrayMenu());
        _updateConnectGlowTicker();
        _stopTrafficMonitor();
        return;
      }
      
      // Проверка на ошибку TUN адаптера
      final errorMsg = result.errorMessage ?? 'Ошибка подключения';
      if (errorMsg.contains('TUN adapter') || errorMsg.contains('wintun') || errorMsg.toLowerCase().contains('interface')) {
        _showFastSnack('Ошибка сети: WinTun адаптер не готов.');
      } else {
        _showFastSnack(errorMsg);
      }
      
      setState(() {
        _status = '\u041e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e';
        _isConnecting = false;
      });
      unawaited(_updateTrayMenu());
      _updateConnectGlowTicker();
      _stopTrafficMonitor();
      return;
    }

    await _saveUri();
    if (!mounted) return;
    setState(() {
      _status = '\u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u043e';
      _isConnecting = false;
    });
    unawaited(_updateTrayMenu());
    _updateConnectGlowTicker();
    _startTrafficMonitor();
    unawaited(_applyDpiEvasionInjector());
    unawaited(_refreshMetrics(silent: true));
  }

  void _onMainConnectButtonPressed({
    required bool isEnabled,
    required bool isRunning,
  }) {
    if (_isConnecting || _isDisconnecting) return;

    if (isRunning) {
      unawaited(_stop());
      return;
    }

    if (!isEnabled) {
      _showFastSnack('Добавьте профиль или вставьте VLESS-конфиг');
      return;
    }

    unawaited(_start());
  }

  /// Дополнительная проверка полного отключения with retry logic
  Future<void> _ensureDisconnected() async {
    int retries = 0;
    const maxRetries = 3;
    
    while (_isRunning && retries < maxRetries) {
      await Future.delayed(const Duration(seconds: 1));
      retries++;
    }
    
    if (_isRunning) {
      // Если после попыток еще подключено - попробуем еще раз отключить
      await _singBoxController.disconnect(
        onStatus: (_) {},
        onLog: (_) {},
      );
      await Future.delayed(const Duration(seconds: 1));
    }
  }


  Future<void> _stop() async {
    // Защита от спама - проверяем, не идёт ли уже отключение или подключение
    if (_isDisconnecting || _isConnecting) return;
    if (!_isRunning) return;
    
    setState(() {
      _isDisconnecting = true;
    });
    
    // Сначала остановить мониторинг трафика
    await _stopTrafficMonitor();
    
    // Остановить DPI injection
    await _dpiEvasionManager.stopNativeInjector();
    
    // Затем отключить sing-box
    await _singBoxController.disconnect(
      onStatus: (value) {
        if (!mounted) return;
        setState(() => _status = _mapStatus(value));
        unawaited(_updateTrayMenu());
      },
      onLog: (line) => _appendLogs([line]),
    );
    
    // Даем времени на полную очистку соединения
    await Future.delayed(const Duration(milliseconds: 500));
    
    if (!mounted) return;
    setState(() {
      _status = '\u041e\u0441\u0442\u0430\u043d\u043e\u0432\u043b\u0435\u043d\u043e';
      _isConnecting = false;
      _isDisconnecting = false;
    });
    unawaited(_updateTrayMenu());
    _updateConnectGlowTicker();
  }

  Future<void> _applyDpiEvasionInjector() async {
    final shouldRunInjector = _dpiEvasionConfig.enableTtlPhantom ||
        _dpiEvasionConfig.enableTcpWindowClamp ||
        _dpiEvasionConfig.enableSniCaseRandomization;
    if (!shouldRunInjector) {
      await _dpiEvasionManager.stopNativeInjector();
      return;
    }
    final link = _currentLink;
    if (link == null) return;
    await _dpiEvasionManager.startForHost(
      link.host,
      link.port,
      enableTcpWindowClamp: _dpiEvasionConfig.enableTcpWindowClamp,
      enableSniRandomization: _dpiEvasionConfig.enableSniCaseRandomization,
    );
  }

  void _updateDpiConfig(DpiEvasionConfig config) {
    setState(() => _dpiEvasionConfig = config);
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) async {
          await prefs.setBool(
            _dpiAggressiveKey,
            config.profile == DpiEvasionProfile.aggressive,
          );
          await prefs.setBool(
            _dpiFragmentationKey,
            config.enableFragmentation,
          );
          await prefs.setBool(
            _dpiTlsFragmentKey,
            config.enableTlsFragment,
          );
          await prefs.setBool(
            _dpiTlsRecordFragmentKey,
            config.enableTlsRecordFragment,
          );
          await prefs.setBool(
            _dpiTrafficNoiseKey,
            config.enableTrafficNoise,
          );
          await prefs.setBool(
            _dpiMultiplexPaddingKey,
            config.enableMultiplexPadding,
          );
          await prefs.setBool(
            _dpiTcpWindowClampKey,
            config.enableTcpWindowClamp,
          );
          await prefs.setBool(
            _dpiSniRandomizationKey,
            config.enableSniCaseRandomization,
          );
        },
      ),
    );
    if (_isRunning) {
      unawaited(_applyDpiEvasionInjector());
    } else {
      final shouldRunInjector = config.enableTtlPhantom ||
          config.enableTcpWindowClamp ||
          config.enableSniCaseRandomization;
      if (!shouldRunInjector) {
        unawaited(_dpiEvasionManager.stopNativeInjector());
      }
    }
  }


  void _appendLogs(Iterable<String> entries) {
    final iterable = entries.where((e) => e.trim().isNotEmpty).toList();
    if (iterable.isEmpty) return;
    _pendingLogLines.addAll(iterable);
    _logFlushTimer ??= Timer(const Duration(milliseconds: 200), () {
      _logFlushTimer = null;
      if (!mounted) return;
      if (_pendingLogLines.isEmpty) return;
      setState(() {
        for (final line in _pendingLogLines) {
          _logLines.add(line);
          if (_logLines.length > 200) {
            _logLines.removeAt(0);
          }
        }
        _pendingLogLines.clear();
      });
    });
  }

  Future<void> _openFullLogView() async {
    final logText = _logLines.isEmpty
        ? 'Лог пуст. Подключитесь к VPN для просмотра сообщений.'
        : _logLines.join('\n');
    final controller = ScrollController();
    await showDialog(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Dialog(
          insetPadding: const EdgeInsets.all(16),
          backgroundColor:
              theme.colorScheme.surfaceContainerHighest.withOpacity(0.9),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 720),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.notes_rounded),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Лог подключения — полноэкранно',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Скопировать лог',
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: logText));
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Лог скопирован в буфер'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy_all_outlined),
                      ),
                      IconButton(
                        tooltip: 'Закрыть',
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Scrollbar(
                          thumbVisibility: true,
                          controller: controller,
                          child: SingleChildScrollView(
                            controller: controller,
                            child: SelectableText(
                              logText,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                height: 1.25,
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
          ),
        );
      },
    );
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
  @override
  void dispose() {
    _logFlushTimer?.cancel();
    _connectGlowController.dispose();
    _windowsPageController.dispose();
    _controller.dispose();
    _logScrollController.dispose();
    if (_isDesktopPlatform) {
      windowManager.removeListener(this);
      _trayManager.removeListener(this);
      unawaited(_trayManager.destroy());
    }
    // Убеждаемся что VPN отключен перед выходом
    if (_isRunning) {
      unawaited(_stop());
    }
    unawaited(_stopTrafficMonitor());
    unawaited(_singBoxController.dispose());
    unawaited(_dpiEvasionManager.stopNativeInjector());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasConnectable = _profiles.isNotEmpty || _hasSubscriptions;
    if (Platform.isWindows) {
      return _buildWindowsShell(hasConnectable);
    }
    if (!hasConnectable) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('neuravpn'),
        ),
        body: _buildEmptyState(),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('neuravpn'),
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
                const Center(child: AnimatedEmoji(emoji: '??', size: 84)),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _showProfileDialog,
                  child: const Text(
                    '\u0412\u0432\u0435\u0441\u0442\u0438 \u043a\u043b\u044e\u0447',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _pasteProfileFromClipboard,
                  child: const Text(
                    '\u0412\u0441\u0442\u0430\u0432\u0438\u0442\u044c \u0438\u0437 \u0431\u0443\u0444\u0435\u0440\u0430 \u043e\u0431\u043c\u0435\u043d\u0430',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWindowsShell(bool hasConnectable) {
    if (_showLoadingScreen) {
      return _buildWindowsLoadingShell();
    }
    return Scaffold(
      backgroundColor: _neuraBlack,
      body: Stack(
        children: [
          const Positioned.fill(
            child: ColoredBox(color: _neuraBlack),
          ),
          if (!kReleaseMode)
            const Positioned.fill(child: NeuralBackground())
          else
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF0A0A0A),
                      Color(0xFF141018),
                      Color(0xFF0A0A0A),
                    ],
                  ),
                ),
              ),
            ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Stack(
                          children: [
                            DragToMoveArea(
                              child: SizedBox(
                                width: double.infinity,
                                height: 56,
                                child: const ColoredBox(
                                  color: Colors.transparent,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                              child: _buildWindowsTitleBar(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (hasConnectable)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: _buildWindowsTabs(),
                          ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: hasConnectable
                              ? PageView(
                                  controller: _windowsPageController,
                                  physics: const PageScrollPhysics(),
                                  onPageChanged: (index) {
                                    final view = _windowsViewAt(index);
                                    if (_windowsView != view) {
                                      setState(() => _windowsView = view);
                                    }
                                    if (view == _WindowsView.splitTunneling &&
                                        Platform.isWindows) {
                                      _loadWindowsApps();
                                    }
                                  },
                                  children: [
                                    _buildWindowsPage(
                                      _buildWindowsConnectionView(),
                                    ),
                                    _buildWindowsPage(
                                      _buildWindowsSplitView(),
                                    ),
                                    _buildWindowsPage(
                                      _buildWindowsSettingsView(),
                                    ),
                                  ],
                                )
                              : SingleChildScrollView(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    0,
                                    24,
                                    24,
                                  ),
                                  child: _buildWindowsEmptyState(),
                                ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_showLoadingScreen,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: _showLoadingScreen
                    ? LoadingScreen(
                        key: const ValueKey('loading'),
                        onComplete: _dismissLoadingScreen,
                      )
                    : const SizedBox.shrink(key: ValueKey('loading-empty')),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWindowsLoadingShell() {
    return Scaffold(
      backgroundColor: _neuraBlack,
      body: Stack(
        children: [
          const Positioned.fill(
            child: ColoredBox(color: _neuraBlack),
          ),
          if (!kReleaseMode)
            const Positioned.fill(child: NeuralBackground())
          else
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF0A0A0A),
                      Color(0xFF141018),
                      Color(0xFF0A0A0A),
                    ],
                  ),
                ),
              ),
            ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 56,
            child: DragToMoveArea(
              child: ColoredBox(color: Colors.transparent),
            ),
          ),
          LoadingScreen(
            key: const ValueKey('loading'),
            onComplete: _dismissLoadingScreen,
          ),
        ],
      ),
    );
  }

  Widget _buildWindowsTitleBar() {
    return Row(
      children: [
        Expanded(
          child: DragToMoveArea(
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: Image.asset(
                    'assets/images/11zon_cropped.png',
                    width: 44,
                    height: 44,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'neuravpn',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            _buildWindowButton(
              icon: Icons.settings,
              onPressed: () => _setWindowsView(_WindowsView.settings),
            ),
            _buildWindowButton(
              icon: Icons.remove,
              onPressed: () => windowManager.minimize(),
            ),
            _buildWindowButton(
              icon: Icons.close,
              hoverColor: _neuraRed.withOpacity(0.2),
              onPressed: () => unawaited(_hideToTray(showHint: true)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWindowButton({
    required IconData icon,
    required VoidCallback onPressed,
    Color? hoverColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          hoverColor: hoverColor ?? Colors.white.withOpacity(0.05),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(icon, size: 16, color: Colors.white70),
          ),
        ),
      ),
    );
  }

  void _setWindowsView(_WindowsView view) {
    if (_windowsView == view) return;
    setState(() => _windowsView = view);
    if (_windowsPageController.hasClients) {
      final index = _windowsViewIndex(view);
      _windowsPageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget _buildWindowsTabs() {
    return AnimatedBuilder(
      animation: _windowsPageController,
      builder: (context, child) {
        final fallback = _windowsViewIndex(_windowsView).toDouble();
        final page =
            _windowsPageController.hasClients ? (_windowsPageController.page ?? fallback) : fallback;
        final currentIndex = page.round().clamp(0, _windowsViewOrder.length - 1);
        final currentView = _windowsViewAt(currentIndex);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: Text(
                _tabLabelForView(currentView),
                key: ValueKey(currentView),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: _windowsViewOrder.asMap().entries.map((entry) {
                final index = entry.key;
                final view = entry.value;
                final distance = (page - index).abs().clamp(0.0, 1.0);
                final t = 1.0 - distance;
                final size = 8.0 + 6.0 * t;
                final isActive = _windowsView == view;

                return GestureDetector(
                  onTap: () => _setWindowsView(view),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    width: size,
                    height: size,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: isActive ? _neuraRed : Colors.white.withOpacity(0.28),
                      shape: BoxShape.circle,
                      boxShadow: isActive
                          ? [
                              BoxShadow(
                                color: _neuraRed.withOpacity(0.45),
                                blurRadius: 8,
                              ),
                            ]
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildWindowsPage(Widget child) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          child,
          const SizedBox(height: 20),
          _buildWindowsFooter(),
        ],
      ),
    );
  }

  Widget _buildWindowsContent() {
    Widget child;
    switch (_windowsView) {
      case _WindowsView.connection:
        child = _buildWindowsConnectionView();
      case _WindowsView.splitTunneling:
        child = _buildWindowsSplitView();
      case _WindowsView.settings:
        child = _buildWindowsSettingsView();
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
        );
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: KeyedSubtree(
        key: ValueKey(_windowsView),
        child: child,
      ),
    );
  }

  Widget _buildWindowsConnectionView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildWindowsConnectionModule(),
        const SizedBox(height: 16),
        _buildWindowsProfilesModule(),
        const SizedBox(height: 16),
        _buildWindowsSmartRoutingModule(),
      ],
    );
  }

  Widget _buildWindowsSplitView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildWindowsSplitModule(),
      ],
    );
  }

  Widget _buildWindowsSettingsView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _neuraCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _neuraSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: const Icon(
                      Icons.system_update_alt,
                      color: _neuraRed,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Обновления',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _checkingUpdates
                        ? null
                        : () => _maybeCheckForUpdates(manual: true),
                    child: Text(_checkingUpdates ? 'Проверка...' : 'Проверить'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _appVersion.isEmpty
                    ? 'Версия: —'
                    : 'Версия: $_appVersion',
                style: TextStyle(color: Colors.white.withOpacity(0.6)),
              ),
              if (_updateResult?.isUpdateAvailable == true) ...[
                const SizedBox(height: 8),
                Text(
                  'Доступна версия ${_updateResult!.latestVersion}',
                  style: const TextStyle(
                    color: _neuraRed,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: () =>
                      _openUrl(_updateResult!.releaseUrl.toString()),
                  style: FilledButton.styleFrom(
                    backgroundColor: _neuraRed,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Открыть релиз на GitHub'),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  'Автопроверка выполняется раз в 12 часов.',
                  style: TextStyle(color: Colors.white.withOpacity(0.5)),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                'Репозиторий: $_updateOwner/$_updateRepo',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.35),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _neuraCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _neuraSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: const Icon(
                      Icons.tune,
                      color: _neuraRed,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Расширенные настройки',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  if (_generatedConfig != null)
                    IconButton(
                      tooltip: 'Показать конфиг',
                      onPressed: () => _showConfigDialog(context),
                      icon: const Icon(Icons.receipt_long, size: 18),
                    ),
                ],
              ),
              const SizedBox(height: 16),
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
        const SizedBox(height: 16),
        _neuraCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _neuraSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    child: const Icon(
                      Icons.code,
                      color: _neuraRed,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Developer mode',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Switch.adaptive(
                    value: _developerMode,
                    activeColor: _neuraRed,
                    onChanged: (value) => _setDeveloperMode(value),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Show advanced diagnostics.',
                style: TextStyle(color: Colors.white.withOpacity(0.7)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildWindowsLogPanel(),
      ],
    );
  }


  Widget _buildWindowsFooter() {
    return const Center(
      child: Text(
        'neuravpn \u00b7 \u0418\u043d\u0442\u0435\u043b\u043b\u0435\u043a\u0442\u0443\u0430\u043b\u044c\u043d\u0430\u044f \u0437\u0430\u0449\u0438\u0442\u0430',
        style: TextStyle(color: Colors.white38, fontSize: 11),
      ),
    );
  }

  Widget _buildWindowsEmptyState() {
    return _neuraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Добавьте первое подключение',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _showProfileDialog,
            child: const Text('Ввести ключ'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _pasteProfileFromClipboard,
            child: const Text('Вставить из буфера обмена'),
          ),
        ],
      ),
    );
  }

  Widget _neuraCard({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(20),
    bool repaintBoundary = true,
  }) {
    final card = Container(
      decoration: BoxDecoration(
        color: _neuraCardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      padding: padding,
      child: child,
    );
    if (!repaintBoundary) {
      return card;
    }
    return RepaintBoundary(child: card);
  }

  Widget _buildWindowsConnectionModule() {
    final isRunning = _isRunning;
    final isEnabled =
        _selectedProfile != null || _controller.text.trim().isNotEmpty;
    final canInteract = !_isConnecting && !_isDisconnecting;
    final statusColor = isRunning
        ? _neuraRed
        : _isConnecting
        ? const Color(0xFFFBBF24)
        : const Color(0xFF6B7280);
    final statusText = isRunning
        ? 'Подключено'
        : _isConnecting
        ? 'Подключение...'
        : 'Не подключено';
    final statusHint = isRunning
        ? 'Соединение защищено'
        : _isConnecting
        ? 'Устанавливается защищённое соединение'
        : 'Нажмите, чтобы подключиться';
    final pingLabel = _pingInProgress
        ? '...'
        : (_pingMs != null ? '$_pingMs ms' : '--');
    final link = _currentLink;
    final protocolLabel =
        link == null ? 'VLESS' : 'VLESS / ${(link.type ?? 'tcp').toUpperCase()}';
    final canRefreshMetrics = _selectedProfile != null && !_pingInProgress;

    return _neuraCard(
      child: Stack(
        children: [
          if (isRunning)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  children: [
                    CustomPaint(
                      painter: _TrafficGraphPainter(
                        samples: List<double>.from(_trafficHistory),
                      ),
                      child: const SizedBox.expand(),
                    ),
                    BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                      child: Container(
                        color: Colors.white.withOpacity(0.02),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_isConnecting)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                  child: CustomPaint(
                    painter: _ConnectionWavePainter(
                      progress: _connectGlowAnimation.value,
                      color: _neuraRed,
                    ),
                    child: Container(
                      color: Colors.white.withOpacity(0.02),
                    ),
                  ),
                ),
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                      boxShadow: [
                        if (isRunning)
                          BoxShadow(
                            color: _neuraRed.withOpacity(0.6),
                            blurRadius: 12,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      statusText,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                  if (isRunning)
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18),
                      color: Colors.white54,
                      onPressed: canRefreshMetrics ? _refreshMetrics : null,
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Center(
                child: MouseRegion(
                  cursor: canInteract
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: canInteract
                        ? () => _onMainConnectButtonPressed(
                              isEnabled: isEnabled,
                              isRunning: isRunning,
                            )
                        : null,
                    child: AnimatedBuilder(
                    animation: _connectGlowAnimation,
                    builder: (context, child) {
                      final rotation = _connectGlowAnimation.value * 2 * math.pi;
                      final pulse = _isConnecting
                          ? 1 + 0.04 * math.sin(rotation)
                          : 1.0;
                      final ring = Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: statusColor,
                            width: 2,
                          ),
                        ),
                      );
                      return Opacity(
                        opacity: canInteract && (isEnabled || isRunning) ? 1 : 0.5,
                        child: Transform.scale(
                          scale: pulse,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (_isConnecting)
                                Transform.rotate(angle: rotation, child: ring)
                              else
                                ring,
                              if (isRunning)
                                Container(
                                  width: 140,
                                  height: 140,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        _neuraRed.withOpacity(0.25),
                                        Colors.transparent,
                                      ],
                                      stops: const [0.0, 0.7],
                                    ),
                                  ),
                                ),
                              Container(
                                width: 104,
                                height: 104,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isRunning ? _neuraRed : _neuraSurface,
                                ),
                                child: Center(
                                  child: Image.asset(
                                    'assets/images/logo.png',
                                    width: 48,
                                    height: 48,
                                    color: Colors.white,
                                    filterQuality: FilterQuality.high,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                statusHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
              if (isRunning) ...[
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _neuraCard(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: const [
                                Icon(Icons.bolt, size: 16, color: _neuraRed),
                                SizedBox(width: 6),
                                Text(
                                  'Задержка',
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              pingLabel,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _neuraCard(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: const [
                                Icon(
                                  Icons.shield_outlined,
                                  size: 16,
                                  color: _neuraRed,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'Протокол',
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              protocolLabel,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWindowsProfilesModule() {
    return _neuraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _neuraSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: const Icon(Icons.person_outline, color: _neuraRed),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Профили подключения',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              IconButton(
                onPressed: _showProfileDialog,
                icon: const Icon(Icons.add, color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 320,
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
    );
  }

  Widget _buildWindowsSmartRoutingModule() {
    return _neuraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _neuraSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: const Icon(Icons.psychology, color: _neuraRed),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Умная маршрутизация',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Что это?',
                icon: const Icon(Icons.help_outline, color: Colors.white70),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => Dialog(
                      backgroundColor: Colors.transparent,
                      insetPadding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 24,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: _neuraCardColor,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.08),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Умная маршрутизация',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Некоторые сайты, где VPN не нужен, открываются без него.\n'
                              'А сайты, которым нужен VPN, идут через него.',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.75),
                                height: 1.35,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: _neuraRed,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 10,
                                  ),
                                ),
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('Понятно'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              Switch.adaptive(
                value: _smartRouting,
                activeColor: _neuraRed,
                onChanged: (value) => _setSmartRouting(value),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWindowsServerLocation() {
    final link = _currentLink;
    final serverLabel = link == null
        ? '\u041e\u043f\u0442\u0438\u043c\u0430\u043b\u044c\u043d\u043e \u00b7 \u0410\u0432\u0442\u043e\u0432\u044b\u0431\u043e\u0440'
        : '${link.host}:${link.port}';
    return _neuraCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _neuraSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: const Icon(Icons.place_outlined, color: _neuraRed),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '\u0421\u0435\u0440\u0432\u0435\u0440',
                  style: TextStyle(color: Colors.white.withOpacity(0.6)),
                ),
                const SizedBox(height: 4),
                Text(
                  serverLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.white38),
        ],
      ),
    );
  }

  Widget _buildWindowsSplitModule() {
    final activeDomains = _activeSplitConfig.domains;
    final activeApps = _activeSplitConfig.applications;
    final theme = Theme.of(context);
    return _neuraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _neuraSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: const Icon(Icons.call_split, color: _neuraRed),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Раздельное туннелирование',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Что это?',
                icon: const Icon(Icons.help_outline, color: Colors.white70),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => Dialog(
                      backgroundColor: Colors.transparent,
                      insetPadding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 24,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: _neuraCardColor,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.08),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Раздельное туннелирование',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Вы выбираете, что идёт через VPN, а что — напрямую.\n\n'
                              'Белый список: через VPN идут только выбранные домены/приложения.\n'
                              'Всё остальное — напрямую.\n\n'
                              'Чёрный список: выбранные домены/приложения идут напрямую.\n'
                              'Всё остальное — через VPN.',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.75),
                                height: 1.35,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: _neuraRed,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 10,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('Понятно'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              Switch.adaptive(
                value: _splitEnabled,
                activeColor: _neuraRed,
                onChanged: (value) => _setSplitEnabled(value),
              ),
            ],
          ),
          const SizedBox(height: 16),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _splitEnabled
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Пресет',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 8),
                      InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          setState(() => _showPresetList = !_showPresetList);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: _neuraSurface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.12),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _activePresetLabel,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              Icon(
                                _showPresetList
                                    ? Icons.keyboard_arrow_up
                                    : Icons.keyboard_arrow_down,
                                color: Colors.white70,
                              ),
                            ],
                          ),
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final offsetAnimation = Tween<Offset>(
                            begin: const Offset(0, -0.08),
                            end: Offset.zero,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: offsetAnimation,
                              child: child,
                            ),
                          );
                        },
                        child: _showPresetList
                            ? Container(
                                key: const ValueKey('preset-list'),
                                margin: const EdgeInsets.only(top: 8),
                                decoration: BoxDecoration(
                                  color: _neuraSurface,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.1),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    _buildPresetListItem(
                                      label: _presetDirty ? 'Свои *' : 'Свои',
                                      selected: !_hasActivePreset,
                                      onTap: () {
                                        _handlePresetSelection(_noPresetValue);
                                        setState(() => _showPresetList = false);
                                      },
                                    ),
                                    for (final preset in _splitPresets)
                                      _buildPresetListItem(
                                        label: preset.name,
                                        selected:
                                            _activePresetName == preset.name,
                                        onTap: () {
                                          _handlePresetSelection(preset.name);
                                          setState(() => _showPresetList = false);
                                        },
                                      ),
                                  ],
                                ),
                              )
                            : const SizedBox.shrink(
                                key: ValueKey('preset-list-empty'),
                              ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Режим',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'whitelist',
                            label: Text('Через VPN'),
                          ),
                          ButtonSegment(
                            value: 'blacklist',
                            label: Text('В обход VPN'),
                          ),
                        ],
                        style: SegmentedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 14,
                          ),
                          backgroundColor: _neuraSurface,
                          selectedBackgroundColor: _neuraRed.withOpacity(0.22),
                          foregroundColor: Colors.white70,
                          selectedForegroundColor: Colors.white,
                          side: BorderSide(color: Colors.white.withOpacity(0.18)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        selected: {_splitMode},
                        onSelectionChanged: (selection) {
                          _changeSplitMode(selection.first);
                        },
                      ),
                      const SizedBox(height: 12),
                      _buildWindowsPresetActionsBar(),
                      const SizedBox(height: 16),
                      _buildSplitEntrySection(
                        title: 'Сайты',
                        icon: Icons.public,
                        items: activeDomains,
                        emptyLabel: 'Домены не добавлены.',
                        onAdd: () => _promptAddEntry(
                          title: 'Добавить домен',
                          hint: 'example.com',
                          onSubmit: _addDomainEntry,
                        ),
                        onRemove: _removeDomainEntry,
                      ),
                      const SizedBox(height: 16),
      _buildSplitEntrySection(
        title: 'Приложения',
        icon: Icons.apps_outlined,
        items: activeApps,
        emptyLabel: 'Приложения не добавлены.',
        onAdd: _showWindowsAppPicker,
        onRemove: _removeApplication,
        labelBuilder: _describeApplicationEntry,
        subtitleBuilder: (value) =>
            _windowsAppLabels.containsKey(value) ? value : '',
        leadingBuilder: (value) =>
            _buildWindowsAppIcon(value, size: 18),
      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildWindowsPresetActionsBar() {
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
        FilledButton(
          onPressed: _presetDirty ? _overwriteActivePreset : null,
          style: FilledButton.styleFrom(
            backgroundColor: _neuraRed,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Обновить пресет'),
        ),
      );
      buttons.add(
        OutlinedButton(
          onPressed: () => _confirmDeletePreset(activePreset!),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white70,
            side: BorderSide(color: Colors.white.withOpacity(0.2)),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Удалить'),
        ),
      );
    } else {
      buttons.add(
        FilledButton(
          onPressed: _promptSavePreset,
          style: FilledButton.styleFrom(
            backgroundColor: _neuraRed,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Сохранить пресет'),
        ),
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: buttons,
    );
  }

  Widget _buildPresetListItem({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              if (selected)
                const Icon(Icons.check, size: 16, color: _neuraRed),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSplitEntrySection({
    required String title,
    required IconData icon,
    required List<String> items,
    required String emptyLabel,
    required Future<void> Function() onAdd,
    required void Function(String value) onRemove,
    String Function(String value)? labelBuilder,
    String Function(String value)? subtitleBuilder,
    Widget Function(String value)? leadingBuilder,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            IconButton(
              onPressed: onAdd,
              icon: const Icon(Icons.add, color: Colors.white54),
              tooltip: 'Добавить',
            ),
          ],
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              emptyLabel,
              style: const TextStyle(color: Colors.white38),
            ),
          )
        else
          Column(
            children: items.map((entry) {
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _neuraSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _neuraRed.withOpacity(0.25)),
                ),
                child: Row(
                  children: [
                      leadingBuilder?.call(entry) ??
                          Icon(icon, size: 16, color: _neuraRed),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              labelBuilder?.call(entry) ?? entry,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70),
                            ),
                            if ((subtitleBuilder?.call(entry) ?? '').isNotEmpty)
                              Text(
                                subtitleBuilder!.call(entry),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                    IconButton(
                      onPressed: () => onRemove(entry),
                      icon: const Icon(Icons.delete, size: 16),
                      color: _neuraRed,
                      tooltip: 'Удалить',
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildWindowsLogPanel() {
    final logText = _logLines.isEmpty
        ? 'Логов пока нет. Запустите VPN, чтобы увидеть события.'
        : _logLines.join('\\n');
    return _neuraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal_rounded, color: Colors.white70),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Логи',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Очистить логи',
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
          Container(
            height: 220,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _neuraSurface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(0.06)),
            ),
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
                    color: Colors.white70,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ],
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
                  color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.25),
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
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
                              label: Text('Через VPN'),
                            ),
                            ButtonSegment(
                              value: 'blacklist',
                              label: Text('В обход VPN'),
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
                  onAdd: Platform.isWindows
                      ? _showWindowsAppPicker
                      : () => _promptAddEntry(
                            title: 'Р”РѕР±Р°РІРёС‚СЊ РїСЂРёР»РѕР¶РµРЅРёРµ',
                            hint: Platform.isAndroid
                                ? 'com.example.app'
                                : 'C:/Program Files/App/app.exe',
                            onSubmit: _addApplication,
                          ),
                  onRemove: _removeApplication,
                  extraContent: Platform.isAndroid
                      ? _buildAndroidAppActions(Theme.of(context))
                      : (Platform.isWindows
                          ? _buildWindowsAppActions(Theme.of(context))
                          : null),
                  labelBuilder: _describeApplicationEntry,
                  avatarBuilder: Platform.isWindows
                      ? (value) => _buildWindowsAppIcon(value, size: 18)
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
                subtitle: 'РСЃРїРѕР»СЊР·РѕРІР°С‚СЊ С‚РµРєСѓС‰РёРµ РЅР°СЃС‚СЂРѕР№РєРё',
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
    final isWindows = Platform.isWindows;
    final gradient = isRunning
        ? [const Color(0xFFFF1B2D), const Color(0xFF51030F)]
        : [const Color(0xFF1A1B22), const Color(0xFF08090F)];
    final screenWidth = MediaQuery.of(context).size.width;
    final compact = screenWidth < 640;
    final isEnabled =
        _selectedProfile != null || _controller.text.trim().isNotEmpty;
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
    final canInteract = !_isConnecting && !_isDisconnecting;
    final connectButton = Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        mouseCursor:
            canInteract ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onHover: (value) {
          if (!canInteract) {
            if (_connectButtonHovered) {
              setState(() => _connectButtonHovered = false);
            }
            return;
          }
          if (_connectButtonHovered != value) {
            setState(() => _connectButtonHovered = value);
          }
        },
        onTap: canInteract
            ? () => _onMainConnectButtonPressed(
                  isEnabled: isEnabled,
                  isRunning: isRunning,
                )
            : null,
        child: AnimatedScale(
          scale: _connectButtonHovered && canInteract ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 150),
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
            opacity: (isEnabled || isRunning) && canInteract ? 1.0 : 0.4,
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
      ),
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

    final decoration = isWindows
        ? BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: scheme.primary.withOpacity(0.15),
            ),
          )
        : BoxDecoration(
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
          );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: EdgeInsets.all(compact ? 16 : 28),
      decoration: decoration,
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
            const SizedBox(height: 12),
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
                TextButton.icon(
                  onPressed: _openFullLogView,
                  icon: const Icon(Icons.open_in_full),
                  label: const Text('Во весь экран'),
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
    Widget Function(String value)? avatarBuilder,
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
                    avatar: avatarBuilder?.call(value),
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

class _WindowsAppEntry {
  const _WindowsAppEntry({
    required this.name,
    required this.path,
    required this.iconPath,
  });

  final String name;
  final String path;
  final String iconPath;
}

class _WindowsAppPickerSheet extends StatefulWidget {
  const _WindowsAppPickerSheet({required this.apps, this.errorMessage});

  final List<_WindowsAppEntry> apps;
  final String? errorMessage;

  @override
  State<_WindowsAppPickerSheet> createState() => _WindowsAppPickerSheetState();
}

class _WindowsAppPickerSheetState extends State<_WindowsAppPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = _query.trim().toLowerCase();
    final filtered = normalizedQuery.isEmpty
        ? widget.apps
        : widget.apps.where((app) {
            final name = app.name.toLowerCase();
            final path = app.path.toLowerCase();
            return name.contains(normalizedQuery) ||
                path.contains(normalizedQuery);
          }).toList();

    final height = MediaQuery.of(context).size.height * 0.7;
    final theme = Theme.of(context);
    const cardColor = Color(0xFF1A1A1A);
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Container(
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 6),
                    Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const ListTile(
                      title: Text(
                        'Выберите приложение',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        autofocus: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Поиск',
                          labelStyle: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                          ),
                          prefixIcon: const Icon(Icons.search, color: Colors.white54),
                        ),
                        onChanged: (value) => setState(() => _query = value),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: height * 0.6,
                      child: filtered.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 18),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Text(
                                      'Приложений не найдено',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: Colors.white70),
                                    ),
                                    if (widget.errorMessage != null &&
                                        widget.errorMessage!.trim().isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 10),
                                        child: Text(
                                          widget.errorMessage!,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: Colors.white54,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final app = filtered[index];
                                final iconPath = app.iconPath;
                                return ListTile(
                                  leading: iconPath.isNotEmpty
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(6),
                                          child: Image.file(
                                            File(iconPath),
                                            width: 24,
                                            height: 24,
                                            fit: BoxFit.cover,
                                          ),
                                        )
                                      : const Icon(Icons.apps_outlined),
                                  title: Text(
                                    app.name,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  subtitle: Text(
                                    app.path,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white54,
                                    ),
                                  ),
                                  onTap: () =>
                                      Navigator.of(context).pop(app.path),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionWavePainter extends CustomPainter {
  _ConnectionWavePainter({
    required this.progress,
    required this.color,
  });

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final basePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color.withOpacity(0.35);
    final accentPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color.withOpacity(0.6);
    final dashedPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withOpacity(0.18);

    final midY = size.height * 0.42;
    final topY = size.height * 0.22;
    final bottomY = size.height * 0.62;

    _drawWave(
      canvas,
      size,
      midY,
      progress * 2 * math.pi,
      basePaint,
    );
    _drawWave(
      canvas,
      size,
      topY,
      progress * 2 * math.pi + 1.4,
      dashedPaint,
      dash: true,
    );
    _drawWave(
      canvas,
      size,
      bottomY,
      progress * 2 * math.pi + 2.2,
      accentPaint,
    );
  }

  void _drawWave(
    Canvas canvas,
    Size size,
    double y,
    double phase,
    Paint paint, {
    bool dash = false,
  }) {
    final path = Path();
    final amplitude = size.height * 0.03;
    for (double x = 0; x <= size.width; x += 4) {
      final dy = math.sin((x / size.width * 2 * math.pi) + phase) * amplitude;
      if (x == 0) {
        path.moveTo(x, y + dy);
      } else {
        path.lineTo(x, y + dy);
      }
    }
    if (!dash) {
      canvas.drawPath(path, paint);
      return;
    }
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + 12, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + 8;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ConnectionWavePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class _TrafficGraphPainter extends CustomPainter {
  _TrafficGraphPainter({required this.samples});

  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = size.height * 0.7;
    final width = size.width - 24;
    final startX = 12.0;
    final spikePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..shader = LinearGradient(
        colors: [
          const Color(0xFF00E676).withOpacity(0.7),
          const Color(0xFFFFD54F).withOpacity(0.9),
        ],
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    if (samples.isEmpty) return;
    final maxSample = samples.reduce(math.max);
    final scale = maxSample <= 0 ? 0 : (size.height * 0.45) / maxSample;
    final step = width / math.max(1, samples.length - 1);

    final path = Path();
    for (int i = 0; i < samples.length; i++) {
      final x = startX + step * i;
      final y = baseline - (samples[i] * scale);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, spikePaint);
  }

  @override
  bool shouldRepaint(covariant _TrafficGraphPainter oldDelegate) {
    return oldDelegate.samples != samples;
  }
}

class _NeuraTrayMenu extends StatelessWidget {
  const _NeuraTrayMenu({
    required this.status,
    required this.canConnect,
    required this.canDisconnect,
    required this.onConnect,
    required this.onDisconnect,
    required this.onShow,
    required this.onExit,
  });

  final String status;
  final bool canConnect;
  final bool canDisconnect;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onShow;
  final VoidCallback onExit;

  static const Color _card = Color(0xFF1A1A1A);
  static const Color _surface = Color(0xFF2A2A2A);
  static const Color _red = Color(0xFFEF4444);

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 6),
            child: Transform.scale(
              scale: 0.98 + (t * 0.02),
              alignment: Alignment.topRight,
              child: child,
            ),
          ),
        );
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.10)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.40),
              blurRadius: 18,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MenuHeader(text: status),
              _MenuDivider(),
              if (canConnect)
                _MenuItem(
                  icon: Icons.power_settings_new,
                  label: 'Подключиться',
                  accent: _red,
                  onTap: onConnect,
                )
              else if (canDisconnect)
                _MenuItem(
                  icon: Icons.power_off,
                  label: 'Отключиться',
                  accent: _red,
                  onTap: onDisconnect,
                )
              else
                _MenuItem(
                  icon: Icons.hourglass_bottom,
                  label: 'Недоступно',
                  disabled: true,
                  onTap: () {},
                ),
              _MenuDivider(),
              _MenuItem(
                icon: Icons.open_in_new,
                label: 'Показать окно',
                onTap: onShow,
              ),
              _MenuDivider(),
              _MenuItem(
                icon: Icons.logout,
                label: 'Выход',
                onTap: onExit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: _NeuraTrayMenu._surface,
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withOpacity(0.85),
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _MenuDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(height: 1, thickness: 1, color: Colors.white.withOpacity(0.06));
  }
}

class _MenuItem extends StatefulWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent,
    this.disabled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? accent;
  final bool disabled;

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = !widget.disabled;
    final bg = _hover && enabled ? Colors.white.withOpacity(0.06) : Colors.transparent;
    final fg = enabled ? Colors.white.withOpacity(0.9) : Colors.white.withOpacity(0.35);
    final iconColor = widget.accent ?? fg;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: bg,
        child: InkWell(
          onTap: enabled ? widget.onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(widget.icon, size: 18, color: iconColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}








