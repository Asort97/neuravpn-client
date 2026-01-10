import 'dart:io';

import 'package:flutter/material.dart';

import '../services/dpi_evasion_config.dart';
import '../services/dpi_evasion_manager.dart';

class DpiEvasionWidget extends StatefulWidget {
  const DpiEvasionWidget({
    super.key,
    required this.manager,
    required this.config,
    this.serverHost,
    this.serverPort,
    this.onConfigChanged,
    this.enabled = true,
  });

  final DpiEvasionManager manager;
  final DpiEvasionConfig config;
  final String? serverHost;
  final int? serverPort;
  final ValueChanged<DpiEvasionConfig>? onConfigChanged;
  final bool enabled;

  @override
  State<DpiEvasionWidget> createState() => _DpiEvasionWidgetState();
}

class _DpiEvasionWidgetState extends State<DpiEvasionWidget> {
  bool _busy = false;
  static const Color _cardColor = Color(0xFF1A1A1A);
  static const Color _surfaceColor = Color(0xFF2A2A2A);
  static const Color _borderColor = Color(0x14FFFFFF);
  static const Color _accentColor = Color(0xFFEF4444);

  bool get _isAggressive =>
      widget.config.profile == DpiEvasionProfile.aggressive;

  bool get _isFragmentationEnabled => widget.config.enableFragmentation;
  bool get _isTlsFragmentEnabled => widget.config.enableTlsFragment;
  bool get _isTlsRecordFragmentEnabled =>
      widget.config.enableTlsRecordFragment;
  bool get _isTrafficNoiseEnabled => widget.config.enableTrafficNoise;
  bool get _isMultiplexPaddingEnabled => widget.config.enableMultiplexPadding;
  bool get _isTcpWindowClampEnabled => widget.config.enableTcpWindowClamp;
  bool get _isSniCaseRandomEnabled => widget.config.enableSniCaseRandomization;

  Future<void> _onToggle(bool value) async {
    if (!widget.enabled || !Platform.isWindows) return;
    if (_busy) return;

    setState(() => _busy = true);
    final nextConfig = widget.config.copyWith(
      profile:
          value ? DpiEvasionProfile.aggressive : DpiEvasionProfile.balanced,
      enableTtlPhantom: value,
    );
    widget.onConfigChanged?.call(nextConfig);

    if (value) {
      if (widget.serverHost != null && widget.serverPort != null) {
        await widget.manager.startForHost(
          widget.serverHost!,
          widget.serverPort!,
          enableTcpWindowClamp: nextConfig.enableTcpWindowClamp,
          enableSniRandomization: nextConfig.enableSniCaseRandomization,
        );
      }
    } else {
      await widget.manager.stopNativeInjector();
    }
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _onFragmentationToggle(bool value) async {
    if (!widget.enabled || !Platform.isWindows) return;
    final nextConfig = widget.config.copyWithFragmentation(value);
    widget.onConfigChanged?.call(nextConfig);
  }

  void _onTlsFragmentToggle(bool value) {
    if (!widget.enabled || !Platform.isWindows) return;
    widget.onConfigChanged?.call(
      widget.config.copyWith(enableTlsFragment: value),
    );
  }

  void _onTlsRecordFragmentToggle(bool value) {
    if (!widget.enabled || !Platform.isWindows) return;
    widget.onConfigChanged?.call(
      widget.config.copyWith(enableTlsRecordFragment: value),
    );
  }

  void _onTrafficNoiseToggle(bool value) {
    if (!widget.enabled || !Platform.isWindows) return;
    widget.onConfigChanged?.call(
      widget.config.copyWith(enableTrafficNoise: value),
    );
  }

  void _onMultiplexPaddingToggle(bool value) {
    if (!widget.enabled || !Platform.isWindows) return;
    widget.onConfigChanged?.call(
      widget.config.copyWith(enableMultiplexPadding: value),
    );
  }

  void _onTcpWindowClampToggle(bool value) {
    if (!widget.enabled || !Platform.isWindows) return;
    widget.onConfigChanged?.call(
      widget.config.copyWith(enableTcpWindowClamp: value),
    );
  }

  void _onSniCaseRandomToggle(bool value) {
    if (!widget.enabled || !Platform.isWindows) return;
    widget.onConfigChanged?.call(
      widget.config.copyWith(enableSniCaseRandomization: value),
    );
  }

  Widget _buildToggleCard({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required bool disabled,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
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
                    disabled
                        ? 'Доступно только на Windows'
                        : subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              activeColor: _accentColor,
              inactiveTrackColor: _surfaceColor,
              onChanged: disabled ? null : onChanged,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSupported = Platform.isWindows;
    final disabled = !isSupported || !widget.enabled;
    final subtitle = disabled
        ? '\u0414\u043e\u0441\u0442\u0443\u043f\u043d\u043e \u0442\u043e\u043b\u044c\u043a\u043e \u043d\u0430 Windows'
        : '\u0414\u043e\u0431\u0430\u0432\u043b\u044f\u0435\u0442 \u0444\u0440\u0430\u0433\u043c\u0435\u043d\u0442\u0430\u0446\u0438\u044e \u0438 TTL phantom \u0434\u043b\u044f \u043e\u0431\u0445\u043e\u0434\u0430 DPI.';

    return Column(
      children: [
        _buildToggleCard(
          title: 'Агрессивная маскировка',
          subtitle: subtitle,
          value: _isAggressive,
          onChanged: _onToggle,
          disabled: disabled,
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        const SizedBox(height: 12),
        _buildToggleCard(
          title: 'Фрагментация TLS (transport)',
          subtitle: 'Дробит TLS hello для снижения DPI-блокировок.',
          value: _isFragmentationEnabled,
          onChanged: _onFragmentationToggle,
          disabled: disabled,
        ),
        const SizedBox(height: 12),
        _buildToggleCard(
          title: 'TLS handshake fragmentation',
          subtitle: 'Экспериментальная настройка. Разбивает ClientHello на части.',
          value: _isTlsFragmentEnabled,
          onChanged: _onTlsFragmentToggle,
          disabled: disabled,
        ),
        const SizedBox(height: 12),
        _buildToggleCard(
          title: 'TLS record fragmentation',
          subtitle:
              'Экспериментальная настройка. Дробит TLS записи на уровне протокола.',
          value: _isTlsRecordFragmentEnabled,
          onChanged: _onTlsRecordFragmentToggle,
          disabled: disabled,
        ),
        const SizedBox(height: 12),
        _buildToggleCard(
          title: 'Traffic noise',
          subtitle:
              'Экспериментальная настройка. Добавляет фоновый трафик для маскировки.',
          value: _isTrafficNoiseEnabled,
          onChanged: _onTrafficNoiseToggle,
          disabled: disabled,
        ),
        const SizedBox(height: 12),
        _buildToggleCard(
          title: 'Multiplex padding',
          subtitle:
              'Экспериментальная настройка. Маскирует длины пакетов внутри туннеля.',
          value: _isMultiplexPaddingEnabled,
          onChanged: _onMultiplexPaddingToggle,
          disabled: disabled,
        ),
        const SizedBox(height: 12),
        _buildToggleCard(
          title: 'TCP Window Size clamp',
          subtitle:
              'Экспериментальная настройка. Ограничивает окно TCP до 64–512 байт.',
          value: _isTcpWindowClampEnabled,
          onChanged: _onTcpWindowClampToggle,
          disabled: disabled,
        ),
        const SizedBox(height: 12),
        _buildToggleCard(
          title: 'SNI case randomization',
          subtitle:
              'Экспериментальная настройка. Случайно меняет регистр домена в SNI.',
          value: _isSniCaseRandomEnabled,
          onChanged: _onSniCaseRandomToggle,
          disabled: disabled,
        ),
      ],
    );
  }
}
