import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'vless/vless_parser.dart';
import 'vless/config_generator.dart';
import 'models/split_tunnel_config.dart';
import 'services/wintun_manager.dart';
import 'services/windows_tun_guard.dart';
import 'models/vpn_profile.dart';

void main() {
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

class _VlessHomePageState extends State<VlessHomePage> {
  final TextEditingController _controller = TextEditingController();
  Process? _process;
  String _status = 'Idle';
  List<String> _logLines = [];
  VlessLink? _parsed;
  File? _configFile;
  String? _generatedConfig;
  SplitTunnelConfig _splitConfig = SplitTunnelConfig();
  List<VpnProfile> _profiles = [];
  VpnProfile? _selectedProfile;
  final WintunManager _wintunManager = WintunManager();
  final WindowsTunGuard _tunGuard = WindowsTunGuard();
  String? _activeInterfaceName;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _checkWintun();
  }

  Future<void> _checkWintun() async {
    final available = await _wintunManager.isWintunAvailable();
    if (!available && mounted) {
      setState(() => _status = 'Предупреждение: wintun.dll не найден');
    }
  }

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

    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _selectedProfile = selected;
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
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Название профиля'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: uriController,
                  decoration: const InputDecoration(labelText: 'VLESS URI'),
                  minLines: 1,
                  maxLines: 3,
                ),
              ],
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
    nameController.dispose();
    uriController.dispose();

    if (!shouldSave || uri.trim().isEmpty) return;
    await _addProfile(name, uri);
  }

  String _ensureUniqueProfileName(String base) {
    if (_profiles.every((profile) => profile.name != base)) return base;
    var counter = 2;
    while (true) {
      final candidate = '$base ($counter)';
      if (_profiles.every((profile) => profile.name != candidate)) {
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
    // Останавливаем старый процесс если есть
    if (_process != null) {
      await _stop();
      // Увеличенная задержка для гарантии освобождения интерфейса
      await Future.delayed(const Duration(seconds: 2));
    }

    final raw = _controller.text.trim();
    final parsed = parseVlessUri(raw);
    if (parsed == null) {
      setState(() => _status = 'Ошибка: неверный формат VLESS URI');
      return;
    }
    
    // Сохраняем URI
    await _saveUri();
    setState(() {
      _parsed = parsed;
      _status = 'Генерация конфига';
      _logLines.clear();
    });

    String inboundTag = WindowsTunGuard.defaultInboundTag;
    String interfaceName = WindowsTunGuard.defaultInterfaceName;
    List<String> interfaceAddresses = const ['172.19.0.1/30'];

    if (Platform.isWindows) {
      setState(() => _status = 'Проверка TUN интерфейса');
      final guardResult = await _tunGuard.prepare();
      _appendLogs(guardResult.logs);

      if (!guardResult.success) {
        setState(() {
          _status = guardResult.requiresElevation
              ? '❌ Нужны права администратора для управления TUN интерфейсом'
              : guardResult.error ?? 'Не удалось подготовить TUN интерфейс';
        });
        return;
      }

      inboundTag = guardResult.inboundTag;
      interfaceName = guardResult.interfaceName;
      interfaceAddresses = guardResult.addresses;
      if (guardResult.leftoverAdapters.isNotEmpty) {
        _tunGuard.cleanupAdapters(guardResult.leftoverAdapters).then(_appendLogs);
      }
      setState(() => _status = 'Генерация конфига');
    }

    _activeInterfaceName = interfaceName;

    final jsonConfig = generateSingBoxConfig(
      parsed,
      _splitConfig,
      inboundTag: inboundTag,
      interfaceName: interfaceName,
      addresses: interfaceAddresses,
    );
    _generatedConfig = jsonConfig;
    final tempDir = Directory.systemTemp.createTempSync('singbox_cfg_');
    final cfgFile = File('${tempDir.path}/config.json');
    cfgFile.writeAsStringSync(jsonConfig);
    _configFile = cfgFile;

    final exePath = _resolveBinaryPath();
    if (exePath == null) {
      setState(() => _status = 'Не найден sing-box.exe');
      return;
    }

    setState(() => _status = 'Запуск процесса');
    try {
      final process = await Process.start(exePath, ['run', '-c', cfgFile.path]);
      _process = process;
      final runInterface = interfaceName;
      setState(() => _status = 'Подключено (TUN: $runInterface)');

      process.stdout.transform(SystemEncoding().decoder).listen((data) {
        setState(() {
          _logLines.add(data.trim());
          if (_logLines.length > 200) _logLines.removeAt(0);
        });
      });
      process.stderr.transform(SystemEncoding().decoder).listen((data) {
        final line = data.trim();
        setState(() {
          _logLines.add('[ERR] $line');
          if (_logLines.length > 200) _logLines.removeAt(0);
          
          // Проверка на ошибку доступа (Access is denied)
          if (line.contains('Access is denied') || line.contains('configure tun interface')) {
            _status = '❌ Нужны права администратора! Запустите приложение от имени администратора';
          }
        });
      });
      process.exitCode.then((code) {
        if (mounted) {
          setState(() {
            if (code == 1 && _logLines.any((l) => l.contains('Access is denied'))) {
              _status = '❌ Ошибка доступа - запустите от администратора';
            } else {
              _status = 'Процесс завершён (код $code)';
            }
            _process = null;
          });
        } else {
          _process = null;
        }
        if (_activeInterfaceName == runInterface) {
          _activeInterfaceName = null;
          _tunGuard.cleanupAdapter(runInterface).then(_appendLogs);
        }
      });
    } catch (e) {
      setState(() => _status = 'Ошибка запуска: $e');
    }
  }

  Future<void> _stop() async {
    final p = _process;
    if (p == null) return;
    setState(() => _status = 'Остановка...');
    
    // Сначала пробуем мягкую остановку
    p.kill(ProcessSignal.sigterm);
    
    // Ждём завершения процесса
    try {
      final exitCode = await p.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          // Если не остановился - принудительно
          p.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      if (exitCode == -1) {
        // Ждём после kill
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } catch (e) {
      // На случай ошибки просто kill
      p.kill(ProcessSignal.sigkill);
      await Future.delayed(const Duration(milliseconds: 500));
    }
    
    // Дополнительная задержка для освобождения TUN интерфейса
    await Future.delayed(const Duration(seconds: 1));
    
    _process = null;

    if (Platform.isWindows && _activeInterfaceName != null) {
      final logs = await _tunGuard.cleanupAdapter(_activeInterfaceName);
      _appendLogs(logs);
      _activeInterfaceName = null;
    }

    if (mounted) setState(() => _status = 'Остановлено');
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

  String? _resolveBinaryPath() {
    final candidates = [
      'sing-box.exe',
      'windows/sing-box.exe',
      'assets/bin/sing-box.exe',
    ];
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.path;
    }
    return null;
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
    _process?.kill();
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
                Card(
                  color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.25),
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
                        const SizedBox(height: 16),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'all', label: Text('Весь трафик')),
                            ButtonSegment(value: 'whitelist', label: Text('Только список')),
                            ButtonSegment(value: 'blacklist', label: Text('Кроме списка')),
                          ],
                          style: SegmentedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
                          ),
                          selected: {_splitConfig.mode},
                          onSelectionChanged: (selection) {
                            setState(() {
                              _splitConfig = _splitConfig.copyWith(mode: selection.first);
                            });
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
                      ? 'Например: vk.com, youtube.com, 8.8.8.8, 1.1.1.0/24'
                      : 'vk.com · 8.8.8.8 · 1.1.1.0/24',
                  icon: Icons.language_outlined,
                  items: _splitConfig.domains,
                  emptyPlaceholder: 'Добавьте домен, IP или CIDR, чтобы направить трафик по выбранному правилу.',
                  onAdd: () => _promptAddEntry(
                    title: 'Добавить домен/IP',
                    hint: 'vk.com или 8.8.8.8/32',
                    onSubmit: _addDomainEntry,
                  ),
                  onRemove: _removeDomainEntry,
                ),
                const SizedBox(height: 16),
                _buildEntrySection(
                  context: context,
                  title: 'Приложения',
                  description: 'Укажите путь к .exe, чтобы приоритизировать трафик приложения.',
                  icon: Icons.apps_outlined,
                  items: _splitConfig.applications,
                  emptyPlaceholder: 'Например: C:/Program Files/Telegram/Telegram.exe',
                  onAdd: () => _promptAddEntry(
                    title: 'Добавить приложение',
                    hint: 'C:/Program Files/App/app.exe',
                    onSubmit: _addApplication,
                  ),
                  onRemove: _removeApplication,
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusHero(BuildContext context, bool isWide) {
    final scheme = Theme.of(context).colorScheme;
    final isRunning = _process != null;
    final gradient = isRunning
      ? [const Color(0xFFFF1B2D), const Color(0xFF51030F)]
      : [const Color(0xFF1A1B22), const Color(0xFF08090F)];
    final icon = isRunning ? Icons.shield : Icons.shield_outlined;
    final hostLabel = _parsed != null ? '${_parsed!.host}:${_parsed!.port}' : 'Хост не выбран';
    final configLabel = _configFile != null ? _configFile!.path : 'Конфиг ещё не сгенерирован';

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 46, color: Colors.white),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _status,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      hostLabel,
                      style: TextStyle(color: Colors.white.withOpacity(0.9)),
                    ),
                  ],
                ),
              ),
              if (_generatedConfig != null)
                TextButton.icon(
                  onPressed: () => _showConfigDialog(context),
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('Config'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _buildInfoPill(context, Icons.account_circle, 'Профиль', _selectedProfile?.name ?? 'Ручной ввод'),
              _buildInfoPill(context, Icons.cloud_outlined, 'Интерфейс', _activeInterfaceName ?? 'wintun0'),
              _buildInfoPill(context, Icons.folder_outlined, 'Config Path', configLabel, maxWidth: isWide ? 320 : 220),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProfileCard(BuildContext context) {
    final theme = Theme.of(context);
    final hasProfiles = _profiles.isNotEmpty;
    final isRunning = _process != null;
    final canConnect = hasProfiles && !isRunning;

    return Card(
      color: theme.colorScheme.surfaceVariant.withOpacity(0.25),
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
                value: _selectedProfile?.name,
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
                  return FilterChip(
                    label: Text(profile.name),
                    selected: isSelected,
                    onSelected: (_) => _selectProfile(profile.name),
                    onDeleted: () => _removeProfileByName(profile.name),
                    backgroundColor: theme.colorScheme.surfaceVariant.withOpacity(0.25),
                    selectedColor: theme.colorScheme.primary.withOpacity(0.25),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: canConnect ? _start : null,
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Подключить'),
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14)),
                  ),
                  OutlinedButton.icon(
                    onPressed: isRunning ? _stop : null,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Отключить'),
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14)),
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
                  _buildInfoPill(context, Icons.history, 'Log lines', _logLines.length.toString()),
                  if (_parsed != null)
                    _buildInfoPill(context, Icons.language, 'Server', '${_parsed!.host}:${_parsed!.port}'),
                  if (_configFile != null)
                    _buildInfoPill(context, Icons.folder_outlined, 'Config Path', _configFile!.path, maxWidth: 320),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLogPanel(BuildContext context) {
    final logText = _logLines.isEmpty ? 'Логи появятся после запуска подключения.' : _logLines.join('\n');
    return Card(
      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.25),
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
            Container(
              constraints: const BoxConstraints(minHeight: 200),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.35),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                child: SelectableText(
                  logText,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
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
  }) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceVariant.withOpacity(0.25),
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
            if (items.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceVariant.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(emptyPlaceholder, style: theme.textTheme.bodySmall),
              )
            else
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: items.map((value) {
                  return InputChip(
                    label: Text(value),
                    onDeleted: () => onRemove(value),
                    backgroundColor: theme.colorScheme.surfaceVariant.withOpacity(0.35),
                    labelStyle: theme.textTheme.bodyMedium,
                  );
                }).toList(),
              ),
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
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) return;
              onSubmit(value);
              Navigator.of(ctx).pop();
            },
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  void _addDomainEntry(String value) {
    setState(() {
      final items = [..._splitConfig.domains];
      if (items.contains(value)) return;
      items.add(value);
      _splitConfig = _splitConfig.copyWith(domains: items);
    });
  }

  void _removeDomainEntry(String value) {
    setState(() {
      final items = [..._splitConfig.domains]..remove(value);
      _splitConfig = _splitConfig.copyWith(domains: items);
    });
  }

  void _addApplication(String value) {
    setState(() {
      final apps = [..._splitConfig.applications];
      if (apps.contains(value)) return;
      apps.add(value);
      _splitConfig = _splitConfig.copyWith(applications: apps);
    });
  }

  void _removeApplication(String value) {
    setState(() {
      final apps = [..._splitConfig.applications]..remove(value);
      _splitConfig = _splitConfig.copyWith(applications: apps);
    });
  }

  Widget _buildInfoPill(BuildContext context, IconData icon, String title, String value, {double? maxWidth}) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth ?? 260),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
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

  String _describeSplitMode() {
    switch (_splitConfig.mode) {
      case 'whitelist':
        return 'Только список';
      case 'blacklist':
        return 'Кроме списка';
      default:
        return 'Весь трафик';
    }
  }
}
