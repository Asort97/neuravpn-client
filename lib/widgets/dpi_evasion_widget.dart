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
      widget.config.enableTtlPhantom &&
      widget.config.enableFragmentation &&
      widget.config.enableTlsFragment;

  bool get _isXrayTlsFragmentationEnabled =>
      widget.config.enableFragmentation && widget.config.enableTlsFragment;
  bool get _isTcpWindowClampEnabled => widget.config.enableTcpWindowClamp;
  bool get _isSniCaseRandomEnabled => widget.config.enableSniCaseRandomization;

  DpiEvasionConfig _normalizeProfile(DpiEvasionConfig config) {
    final isAggressive =
        config.enableTtlPhantom &&
        config.enableFragmentation &&
        config.enableTlsFragment;
    return config.copyWith(
      profile: isAggressive
          ? DpiEvasionProfile.aggressive
          : DpiEvasionProfile.balanced,
    );
  }

  Future<void> _onToggle(bool value) async {
    if (!widget.enabled || !Platform.isWindows) return;
    if (_busy) return;

    setState(() => _busy = true);
    final nextConfig = _normalizeProfile(
      widget.config.copyWith(
        enableTtlPhantom: value,
        enableFragmentation: value,
        enableTlsFragment: value,
        tlsFragmentFallbackDelay: value
            ? (widget.config.tlsFragmentFallbackDelay ??
                  const Duration(milliseconds: 500))
            : null,
      ),
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

  Future<void> _onXrayTlsFragmentationToggle(bool value) async {
    if (!widget.enabled || !Platform.isWindows) return;
    final nextConfig = _normalizeProfile(
      widget.config.copyWith(
        enableFragmentation: value,
        enableTlsFragment: value,
        tlsFragmentFallbackDelay: value
            ? (widget.config.tlsFragmentFallbackDelay ??
                  const Duration(milliseconds: 500))
            : null,
      ),
    );
    widget.onConfigChanged?.call(nextConfig);
  }

  void _onTcpWindowClampToggle(bool value) {
    if (!widget.enabled || !Platform.isWindows) return;
    widget.onConfigChanged?.call(
      _normalizeProfile(widget.config.copyWith(enableTcpWindowClamp: value)),
    );
  }

  void _onSniCaseRandomToggle(bool value) {
    if (!widget.enabled || !Platform.isWindows) return;
    widget.onConfigChanged?.call(
      _normalizeProfile(
        widget.config.copyWith(enableSniCaseRandomization: value),
      ),
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
                    disabled ? 'Доступно только на Windows' : subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
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
        : '\u0412\u043a\u043b\u044e\u0447\u0430\u0435\u0442 TTL phantom \u0438 Xray TLS fragmentation \u0434\u043b\u044f \u0431\u043e\u043b\u0435\u0435 \u0436\u0435\u0441\u0442\u043a\u043e\u0433\u043e DPI bypass.';

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
          title: 'TLS fragmentation (Xray)',
          subtitle:
              'Включает transport-level fragmentation для TLS-трафика в Xray.',
          value: _isXrayTlsFragmentationEnabled,
          onChanged: _onXrayTlsFragmentationToggle,
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
