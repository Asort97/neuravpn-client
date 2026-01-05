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

  Future<void> _onToggle(bool value) async {
    if (!widget.enabled || !Platform.isWindows) return;
    if (_busy) return;

    setState(() => _busy = true);
    final nextConfig =
        value ? DpiEvasionConfig.aggressive : DpiEvasionConfig.balanced;
    widget.onConfigChanged?.call(nextConfig);

    if (value) {
      if (widget.serverHost != null && widget.serverPort != null) {
        await widget.manager.startForHost(widget.serverHost!, widget.serverPort!);
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

  @override
  Widget build(BuildContext context) {
    final isSupported = Platform.isWindows;
    final disabled = !isSupported || !widget.enabled;
    final subtitle = disabled
        ? '\u0414\u043e\u0441\u0442\u0443\u043f\u043d\u043e \u0442\u043e\u043b\u044c\u043a\u043e \u043d\u0430 Windows'
        : '\u0414\u043e\u0431\u0430\u0432\u043b\u044f\u0435\u0442 \u0444\u0440\u0430\u0433\u043c\u0435\u043d\u0442\u0430\u0446\u0438\u044e \u0438 TTL phantom \u0434\u043b\u044f \u043e\u0431\u0445\u043e\u0434\u0430 DPI.';

    return Column(
      children: [
        Container(
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
                      const Text(
                        '\u0410\u0433\u0440\u0435\u0441\u0441\u0438\u0432\u043d\u0430\u044f \u043c\u0430\u0441\u043a\u0438\u0440\u043e\u0432\u043a\u0430',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Theme.of(context).hintColor),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _isAggressive,
                  activeColor: _accentColor,
                  inactiveTrackColor: _surfaceColor,
                  onChanged: disabled ? null : _onToggle,
                ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
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
                      const Text(
                        '\u0424\u0440\u0430\u0433\u043c\u0435\u043d\u0442\u0430\u0446\u0438\u044f TLS',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        disabled
                            ? '\u0414\u043e\u0441\u0442\u0443\u043f\u043d\u043e \u0442\u043e\u043b\u044c\u043a\u043e \u043d\u0430 Windows'
                            : '\u0420\u0430\u0437\u0431\u0438\u0432\u0430\u0435\u0442 TLS hello \u0434\u043b\u044f \u0441\u043d\u0438\u0436\u0435\u043d\u0438\u044f DPI-\u0431\u043b\u043e\u043a\u0438\u0440\u043e\u0432\u043e\u043a.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Theme.of(context).hintColor),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _isFragmentationEnabled,
                  activeColor: _accentColor,
                  inactiveTrackColor: _surfaceColor,
                  onChanged: disabled ? null : _onFragmentationToggle,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
