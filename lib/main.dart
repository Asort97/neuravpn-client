import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_apps/device_apps.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'vless/vless_parser.dart';
import 'models/split_tunnel_config.dart';
import 'models/split_tunnel_preset.dart';
import 'services/singbox_controller.dart';
import 'models/vpn_profile.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1100, 760),
      minimumSize: Size(900, 640),
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
          border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
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

class _VlessHomePageState extends State<VlessHomePage> with TrayListener, WindowListener {
  final TextEditingController _controller = TextEditingController();
  String _status = 'Idle';
  final List<String> _logLines = [];
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

    VlessLink? get _parsed => _singBoxController.parsedLink;
  File? get _configFile => _singBoxController.configFile;
  String? get _generatedConfig => _singBoxController.generatedConfig;
  bool get _isDesktopPlatform => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  bool get _hasActivePreset =>
      _activePresetName != null && _splitPresets.any((preset) => preset.name == _activePresetName);
  String get _activePresetLabel {
    if (_activePresetName == null) return 'Не выбрано';
    return _presetDirty ? '${_activePresetName!}*' : _activePresetName!;
  }

  void _showFastSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
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
      setState(() => _status = 'Предупреждение: wintun.dll не найден');
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
      apps.sort((a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _androidInstalledApps = apps;
        _androidAppLabels = {for (final app in apps) app.packageName: app.appName};
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
      _showFastSnack('Список приложений пуст. Обновите список и попробуйте снова.');
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
              onPressed: _androidAppsLoading ? null : () => _loadAndroidApps(force: true),
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
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
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

  bool get _isRunning => _singBoxController.isRunning;

  String get _interfaceLabel => _singBoxController.interfaceLabel;

  Future<void> _loadInitialData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedProfiles = prefs.getString('vpn_profiles');
    var profiles = VpnProfile.listFromJsonString(savedProfiles);

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

    final rawState = prefs.getString(_splitConfigPrefsKey) ?? prefs.getString(_legacySplitConfigKey);
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

            if (decoded['presets'] is List) {
              restoredPresets = (decoded['presets'] as List)
                  .whereType<Map<String, dynamic>>()
                  .map(SplitTunnelPreset.fromJson)
                  .toList();
            }
          } else {
            final legacyDomains = _normalizeStringList(decoded['domains']) ?? const <String>[];
            final legacyApps = _normalizeStringList(decoded['applications']) ?? const <String>[];
            final mode = _normalizeSplitMode(decoded['mode']?.toString());
            restoredMode = mode;
            restoredMap = {
              mode: SplitTunnelConfig(mode: mode, domains: legacyDomains, applications: legacyApps),
            };
          }
        }
      } catch (_) {
        // ignore corrupted prefs
      }
    }

    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _selectedProfile = selected;
      if (restoredMap != null) {
        for (final entry in _splitConfigs.keys.toList()) {
          final restored = restoredMap[entry];
          _splitConfigs[entry] = (restored ?? SplitTunnelConfig(mode: entry)).copyWith(mode: entry);
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
      return;
    }
    await prefs.setString('vpn_profiles', VpnProfile.listToJsonString(_profiles));
  }

  Future<void> _persistSelectedProfile() async {
    final prefs = await SharedPreferences.getInstance();
    if (_selectedProfile != null) {
      await prefs.setString('vpn_profile_selected', _selectedProfile!.name);
    } else {
      await prefs.remove('vpn_profile_selected');
    }
  }

  Future<void> _saveUri() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vless_uri', _controller.text.trim());
  }

  SplitTunnelConfig get _activeSplitConfig => _splitConfigs[_splitMode] ?? _splitConfigs['all']!;

  Future<void> _persistSplitState() async {
    final prefs = await SharedPreferences.getInstance();
    final configsPayload = _splitConfigs.map((key, value) => MapEntry(key, value.copyWith(mode: key).toJson()));
    final payload = jsonEncode({
      'mode': _splitMode,
      'configs': configsPayload,
      'presets': _splitPresets.map((preset) => preset.toJson()).toList(),
      'activePreset': _activePresetName,
    });
    await prefs.setString(_splitConfigPrefsKey, payload);
    await prefs.remove(_legacySplitConfigKey);
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
    final menu = Menu(items: [
      MenuItem(key: _trayShowKey, label: 'Показать окно'),
      MenuItem.separator(),
      MenuItem(key: _trayExitKey, label: 'Выход'),
    ]);
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
      final remaining = _splitPresets.where((p) => p.name != preset.name).toList();
      _splitPresets = [preset, ...remaining];
      _activePresetName = preset.name;
      _presetDirty = false;
    });
    unawaited(_persistSplitState());
    _showFastSnack('Пресет "${preset.name}" сохранен');
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
    _showFastSnack('Пресет "${preset.name}" перезаписан');
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
      _showFastSnack('Пресет "${preset.name}" применен');
    }
  }

  void _handlePresetSelection(String value) {
    if (value == _noPresetValue) {
      setState(() {
        _activePresetName = null;
        _presetDirty = false;
        _splitConfigs[_splitMode] = SplitTunnelConfig(mode: _splitMode);
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
    final shouldDelete = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Удалить пресет?'),
            content: Text('Пресет "${preset.name}" будет удален без возможности восстановления.'),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Удалить')),
            ],
          ),
        ) ??
        false;
    if (!shouldDelete) return;
    setState(() {
      _splitPresets = _splitPresets.where((p) => p.name != preset.name).toList();
      if (_activePresetName == preset.name) {
        _activePresetName = null;
        _presetDirty = false;
      }
    });
    unawaited(_persistSplitState());
    _showFastSnack('Пресет "${preset.name}" удален');
  }

  String _defaultPresetName() => _ensureUniquePresetName('Пресет ${_splitPresets.length + 1}');

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
    final baseName = name.trim().isEmpty ? 'Profile ${_profiles.length + 1}' : name.trim();
    final uniqueName = _ensureUniqueProfileName(baseName);
    final profile = VpnProfile(name: uniqueName, uri: trimmedUri);

    setState(() {
      _profiles = [..._profiles, profile];
      _selectedProfile = profile;
    });
    _controller.text = trimmedUri;
    await _persistProfiles();
    await _persistSelectedProfile();
  }

  Future<void> _removeProfileByName(String name) async {
    final updated = _profiles.where((profile) => profile.name != name).toList();
    setState(() {
      _profiles = updated;
      if (_selectedProfile?.name == name) {
        _selectedProfile = updated.isNotEmpty ? updated.first : null;
        _controller.text = _selectedProfile?.uri ?? '';
      }
    });
    await _persistProfiles();
    await _persistSelectedProfile();
  }

  Future<void> _showProfileDialog() async {
    final defaultName = _ensureUniqueProfileName('Profile ${_profiles.length + 1}');
    final nameController = TextEditingController(text: defaultName);
    final uriController = TextEditingController(text: _controller.text.trim());
    final shouldSave = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Новый профиль VLESS'),
            content: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Название профиля'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: uriController,
                      decoration: const InputDecoration(labelText: 'VLESS URI'),
                      minLines: 3,
                      maxLines: 8,
                      keyboardType: TextInputType.multiline,
                      autofillHints: const [AutofillHints.url],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Сохранить'),
              ),
            ],
          ),
        ) ??
        false;

    final name = nameController.text;
    final uri = uriController.text;

    if (!shouldSave || uri.trim().isEmpty) return;
    await _addProfile(name, uri);
  }

  Future<void> _showEditProfileDialog(VpnProfile profile) async {
    final nameController = TextEditingController(text: profile.name);
    final uriController = TextEditingController(text: profile.uri);
    final shouldSave = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Редактировать профиль'),
            content: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Название профиля'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: uriController,
                      decoration: const InputDecoration(labelText: 'VLESS URI'),
                      minLines: 3,
                      maxLines: 8,
                      keyboardType: TextInputType.multiline,
                      autofillHints: const [AutofillHints.url],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Сохранить')),
            ],
          ),
        ) ??
        false;

    final newNameRaw = nameController.text.trim();
    final newUri = uriController.text.trim();

    if (!shouldSave || newUri.isEmpty) return;

    var finalName = newNameRaw.isEmpty ? profile.name : newNameRaw;
    if (finalName != profile.name) {
      finalName = _ensureUniqueProfileName(finalName, skipName: profile.name);
    }

    final updated = VpnProfile(name: finalName, uri: newUri);

    setState(() {
      _profiles = _profiles.map((p) => p.name == profile.name ? updated : p).toList();
      if (_selectedProfile?.name == profile.name) {
        _selectedProfile = updated;
        _controller.text = newUri;
      }
    });
    await _persistProfiles();
    await _persistSelectedProfile();
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

  Future<void> _selectProfile(String? name) async {
    if (name == null) {
      setState(() => _selectedProfile = null);
      await _persistSelectedProfile();
      return;
    }
    VpnProfile? match;
    for (final profile in _profiles) {
      if (profile.name == name) {
        match = profile;
        break;
      }
    }
    if (match == null) return;
    final selected = match;
    setState(() {
      _selectedProfile = selected;
      _controller.text = selected.uri;
    });
    await _persistSelectedProfile();
  }

  Future<void> _start() async {
    if (_isRunning) {
      await _stop();
      await Future.delayed(const Duration(seconds: 2));
    }

    setState(() {
      _status = 'Подготовка подключения';
      _logLines.clear();
    });

    final result = await _singBoxController.connect(
      rawUri: _controller.text,
      splitConfig: _activeSplitConfig,
      onStatus: (value) {
        if (!mounted) return;
        setState(() => _status = value);
      },
      onLog: (line) => _appendLogs([line]),
    );

    if (!result.success) {
      if (!mounted) return;
      setState(() => _status = result.errorMessage ?? 'Ошибка подключения');
      return;
    }

    await _saveUri();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _stop() async {
    if (!_isRunning) return;
    await _singBoxController.disconnect(
      onStatus: (value) {
        if (!mounted) return;
        setState(() => _status = value);
      },
      onLog: (line) => _appendLogs([line]),
    );
    if (!mounted) return;
    setState(() {});
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

  Future<void> _copyStatusToClipboard() async {
    await Clipboard.setData(ClipboardData(text: _status));
    if (!mounted) return;
    _showFastSnack('Состояние скопировано');
  }

  void _showConfigDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Generated sing-box Config'),
        content: SingleChildScrollView(
          child: SelectableText(
            _generatedConfig ?? '',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _logScrollController.dispose();
    if (_isDesktopPlatform) {
      windowManager.removeListener(this);
      _trayManager.removeListener(this);
      unawaited(_trayManager.destroy());
    }
    unawaited(_singBoxController.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('VLESS VPN Client (Prototype)'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Connection'),
              Tab(text: 'Split Tunneling'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildConnectionTab(),
            _buildSplitTunnelTab(),
          ],
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
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _buildPresetPicker(context),
                const SizedBox(height: 16),
                Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.25),
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.layers_outlined, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 12),
                            const Text('Split Tunneling', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Выберите режим, по которому будет распределяться трафик.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
                        ),
                        const SizedBox(height: 14),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'all', label: Text('Весь трафик')),
                            ButtonSegment(value: 'whitelist', label: Text('Белый список')),
                            ButtonSegment(value: 'blacklist', label: Text('Черный список')),
                          ],
                          style: SegmentedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
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
                  title: 'Домены и IP',
                  description: isWide
                      ? 'Примеры: vk.com, youtube.com, 8.8.8.8, 1.1.1.0/24'
                      : 'vk.com · 8.8.8.8 · 1.1.1.0/24',
                  icon: Icons.language_outlined,
                  items: _activeSplitConfig.domains,
                  emptyPlaceholder: 'Добавьте домены, IP или подсети, чтобы направить их в нужном режиме.',
                  onAdd: () => _promptAddEntry(
                    title: 'Добавить домен или IP',
                    hint: 'vk.com или 8.8.8.8/32',
                    onSubmit: _addDomainEntry,
                  ),
                  onRemove: _removeDomainEntry,
                ),
                const SizedBox(height: 16),
                _buildEntrySection(
                  context: context,
                  title: 'Приложения',
                  description: Platform.isAndroid
                      ? 'Выберите приложение или введите package name вручную.'
                      : 'Укажите путь к .exe, чтобы исключить или направить его через VPN.',
                  icon: Icons.apps_outlined,
                  items: _activeSplitConfig.applications,
                  emptyPlaceholder: Platform.isAndroid
                      ? 'Пример: package:com.telegram.messenger'
                      : 'Пример: C:/Program Files/Telegram/Telegram.exe',
                  onAdd: () => _promptAddEntry(
                    title: 'Добавить приложение',
                    hint: Platform.isAndroid ? 'com.example.app' : 'C:/Program Files/App/app.exe',
                    onSubmit: _addApplication,
                  ),
                  onRemove: _removeApplication,
                  extraContent: Platform.isAndroid ? _buildAndroidAppActions(Theme.of(context)) : null,
                  labelBuilder: Platform.isAndroid ? _describeApplicationEntry : null,
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
    final selectedValue = _hasActivePreset ? _activePresetName! : _noPresetValue;

    Widget buildTile({
      required String title,
      required String subtitle,
      required bool selected,
      IconData icon = Icons.bookmark_border,
    }) {
      return Row(
        children: [
          Icon(icon, size: 18, color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          ),
          if (selected) Icon(Icons.check, size: 18, color: theme.colorScheme.primary),
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
                title: 'Не выбрано',
                subtitle: 'Настроить и сохранить свой пресет',
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
                        '${_describeSplitMode(preset.mode)} · домены: ${preset.domains.length}, приложения: ${preset.applications.length}',
                    selected: selectedValue == preset.name,
                    icon: Icons.bookmark_outline,
                  ),
                ),
              );
            }
          } else {
            items.add(
              const PopupMenuItem(
                enabled: false,
                child: Text('Сохраненных пресетов пока нет'),
              ),
            );
          }
          return items;
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: theme.colorScheme.primary.withOpacity(0.2)),
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
              Text('Активный пресет', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmarks_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    _activePresetLabel,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
              if (_presetDirty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Есть несохраненные изменения',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
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
          label: const Text('Перезаписать пресет'),
        ),
      );
      buttons.add(
        OutlinedButton.icon(
          onPressed: () => _confirmDeletePreset(activePreset!),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Удалить пресет'),
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
                'Настройки отличаются от сохраненного пресета',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
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
    final icon = isRunning ? Icons.shield : Icons.shield_outlined;
    final hostLabel = _parsed != null ? '${_parsed!.host}:${_parsed!.port}' : 'Хост не выбран';
    final configLabel = Platform.isWindows
        ? (_configFile != null ? _configFile!.path : 'Конфиг ещё не сгенерирован')
        : (_generatedConfig != null ? 'Передан в сервис' : 'Конфиг ещё не сгенерирован');
    final screenWidth = MediaQuery.of(context).size.width;
    final compactWidth = (screenWidth - 60).clamp(200.0, 320.0);
    final pillMaxWidth = isWide ? 240.0 : compactWidth;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 640;
        final actions = Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _copyStatusToClipboard,
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('Скопировать состояние'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            ),
            if (_generatedConfig != null)
              TextButton.icon(
                onPressed: () => _showConfigDialog(context),
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Config'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
          ],
        );

        final statusTexts = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              _status,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(
              hostLabel,
              style: TextStyle(color: Colors.white.withOpacity(0.9)),
            ),
          ],
        );

        final header = Flex(
          direction: compact ? Axis.vertical : Axis.horizontal,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 46, color: Colors.white),
            SizedBox(width: compact ? 0 : 16, height: compact ? 16 : 0),
            compact
                ? statusTexts
                : Expanded(child: statusTexts),
            if (!compact) ...[const SizedBox(width: 16), actions],
          ],
        );

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(colors: gradient, begin: Alignment.topLeft, end: Alignment.bottomRight),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withOpacity(isRunning ? 0.25 : 0.1),
                blurRadius: 30,
                offset: const Offset(0, 20),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              if (compact) ...[
                const SizedBox(height: 16),
                actions,
              ],
              const SizedBox(height: 20),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _buildInfoPill(context, Icons.account_circle, 'Профиль', _selectedProfile?.name ?? 'Ручной ввод', maxWidth: pillMaxWidth),
                  _buildInfoPill(context, Icons.cloud_outlined, 'Интерфейс', _interfaceLabel, maxWidth: pillMaxWidth),
                  _buildInfoPill(context, Icons.folder_outlined, 'Config Path', configLabel, maxWidth: pillMaxWidth),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProfileCard(BuildContext context) {
    final theme = Theme.of(context);
    final hasProfiles = _profiles.isNotEmpty;
    final isRunning = _isRunning;
    final canConnect = hasProfiles && !isRunning;

    return Card(
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.25),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person_outline, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Профили VLESS', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: 'Добавить профиль',
                  onPressed: () {
                    _showProfileDialog();
                  },
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (!hasProfiles) ...[
              Text(
                'Подключение выполняется через сохранённые профили. Добавьте свой первый VLESS ключ через плюс.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _showProfileDialog,
                child: const Text('Создать профиль'),
              ),
            ] else ...[
              DropdownButtonFormField<String>(
                initialValue: _selectedProfile?.name,
                decoration: const InputDecoration(labelText: 'Активный профиль'),
                items: _profiles
                    .map(
                      (profile) => DropdownMenuItem(
                        value: profile.name,
                        child: Text(profile.name, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  _selectProfile(value);
                },
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _profiles.map((profile) {
                  final isSelected = _selectedProfile?.name == profile.name;
                  final chip = FilterChip(
                    label: Text(profile.name),
                    selected: isSelected,
                    onSelected: (_) => _selectProfile(profile.name),
                    onDeleted: () => _removeProfileByName(profile.name),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest.withOpacity(0.25),
                    selectedColor: theme.colorScheme.primary.withOpacity(0.25),
                  );
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      chip,
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: 'Редактировать профиль',
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        onPressed: () => _showEditProfileDialog(profile),
                      ),
                    ],
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: hasProfiles ? (_isRunning ? _stop : _start) : null,
                    icon: Icon(_isRunning ? Icons.stop_circle_outlined : Icons.power_settings_new),
                    label: Text(_isRunning ? 'Отключить' : 'Подключить'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                      backgroundColor: _isRunning ? theme.colorScheme.error : theme.colorScheme.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _generatedConfig != null ? () => _showConfigDialog(context) : null,
                    icon: const Icon(Icons.receipt_long),
                    label: const Text('Показать конфиг'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Divider(color: theme.colorScheme.onSurface.withOpacity(0.08)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  _buildInfoPill(context, Icons.route, 'Split Mode', _describeSplitMode()),
                  _buildInfoPill(context, Icons.bookmark_outline, 'Split Preset', _activePresetLabel),
                  _buildInfoPill(context, Icons.history, 'Log lines', _logLines.length.toString()),
                  if (_parsed != null)
                    _buildInfoPill(context, Icons.language, 'Server', '${_parsed!.host}:${_parsed!.port}'),
                  if (_configFile != null)
                    _buildInfoPill(context, Icons.folder_outlined, 'Config Path', _configFile!.path, maxWidth: 240),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLogPanel(BuildContext context) {
    final logText = _logLines.isEmpty ? 'Логи появляются после запуска подключения.' : _logLines.join('\n');
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.25),
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
                  child: Text('Журнал', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: 'Очистить',
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
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.35),
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
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
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
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(description, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
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
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.25),
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
                    backgroundColor: theme.colorScheme.surfaceContainerHighest.withOpacity(0.35),
                    labelStyle: theme.textTheme.bodyMedium,
                  );
                }).toList(),
              ),
            if (footer != null) ...[
              const SizedBox(height: 12),
              footer,
            ],
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

  Widget _buildInfoPill(BuildContext context, IconData icon, String title, String value, {double? maxWidth}) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth ?? 220),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
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
                  Text(title, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  String _describeSplitMode([String? value]) {
    final mode = value ?? _splitMode;
    switch (mode) {
      case 'whitelist':
        return 'Белый список';
      case 'blacklist':
        return 'Черный список';
      default:
        return 'Весь трафик';
    }
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
            return name.contains(normalizedQuery) || package.contains(normalizedQuery);
          }).toList();

    final height = MediaQuery.of(context).size.height * 0.7;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            const ListTile(
              title: Text('Выберите приложение'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Поиск по названию или пакету',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('Совпадений не найдено'))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final app = filtered[index];
                        return ListTile(
                          leading: const Icon(Icons.apps_outlined),
                          title: Text(app.appName),
                          subtitle: Text(app.packageName),
                          onTap: () => Navigator.of(context).pop(app.packageName),
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














