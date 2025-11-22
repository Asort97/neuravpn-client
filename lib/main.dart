import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'vless/vless_parser.dart';
import 'vless/config_generator.dart';
import 'models/split_tunnel_config.dart';
import 'services/wintun_manager.dart';
import 'services/windows_tun_guard.dart';

void main() {
  runApp(const VpnApp());
}

class VpnApp extends StatelessWidget {
  const VpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VLESS VPN Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF261D35)),
        useMaterial3: true,
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
  final WintunManager _wintunManager = WintunManager();
  final WindowsTunGuard _tunGuard = WindowsTunGuard();
  String? _activeInterfaceName;

  @override
  void initState() {
    super.initState();
    _loadSavedUri();
    _checkWintun();
  }

  Future<void> _checkWintun() async {
    final available = await _wintunManager.isWintunAvailable();
    if (!available && mounted) {
      setState(() => _status = 'Предупреждение: wintun.dll не найден');
    }
  }

  Future<void> _loadSavedUri() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUri = prefs.getString('vless_uri');
    if (savedUri != null && savedUri.isNotEmpty) {
      _controller.text = savedUri;
    }
  }

  Future<void> _saveUri() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vless_uri', _controller.text.trim());
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
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'VLESS URI',
                hintText: 'vless://uuid@host:port?type=ws&security=tls#tag',
                border: OutlineInputBorder(),
              ),
              minLines: 1,
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _process == null ? _start : null,
                  child: const Text('Start'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _process != null ? _stop : null,
                  child: const Text('Stop'),
                ),
                const SizedBox(width: 12),
                if (_generatedConfig != null)
                  ElevatedButton(
                    onPressed: () => _showConfigDialog(context),
                    child: const Text('Show Config'),
                  ),
                const SizedBox(width: 12),
                if (_parsed != null)
                  Text('Host: ${_parsed!.host}:${_parsed!.port}', style: const TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 12),
            Text('Статус: $_status'),
            if (_configFile != null)
              Text('Config: ${_configFile!.path}', style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  _logLines.join('\n'),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      );
  }

  Widget _buildSplitTunnelTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Режим Split Tunneling:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('Весь трафик')),
              ButtonSegment(value: 'whitelist', label: Text('Только список')),
              ButtonSegment(value: 'blacklist', label: Text('Кроме списка')),
            ],
            selected: {_splitConfig.mode},
            onSelectionChanged: (Set<String> selection) {
              setState(() {
                _splitConfig = _splitConfig.copyWith(mode: selection.first);
              });
            },
          ),
          const SizedBox(height: 16),
          const Text('Домены и IP (один на строку):', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: TextEditingController(text: _splitConfig.domains.join('\n')),
              decoration: const InputDecoration(
                hintText: 'youtube.com\n8.8.8.8\n1.1.1.0/24',
                border: OutlineInputBorder(),
              ),
              maxLines: null,
              expands: true,
              onChanged: (value) {
                final lines = value.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
                _splitConfig = _splitConfig.copyWith(domains: lines);
              },
            ),
          ),
          const SizedBox(height: 16),
          const Text('Приложения (пути к .exe):', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Примечание: Для проксирования приложений используйте Proxifier или аналог', 
            style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic)),
          const SizedBox(height: 8),
          Expanded(
            flex: 1,
            child: TextField(
              controller: TextEditingController(text: _splitConfig.applications.join('\n')),
              decoration: const InputDecoration(
                hintText: 'C:\\Program Files\\App\\app.exe',
                border: OutlineInputBorder(),
              ),
              maxLines: null,
              expands: true,
              onChanged: (value) {
                final lines = value.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
                _splitConfig = _splitConfig.copyWith(applications: lines);
              },
            ),
          ),
        ],
      ),
    );
  }
}
