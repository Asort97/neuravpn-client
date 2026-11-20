import 'package:flutter/material.dart';

import '../services/profile_availability.dart';
import 'neura_ui.dart';

/// Per-row probe result: nothing before a check, then a short verdict people
/// can compare at a glance ("120 мс", "4/20 · 120 мс", "таймаут").
class ProfileAvailabilityIndicator extends StatelessWidget {
  const ProfileAvailabilityIndicator({super.key, required this.result});
  final ProfileCheckResult result;

  static const Color _good = Color(0xFF65C998);
  static const Color _bad = Color(0xFFF87171);
  static const Color _warn = Color(0xFFE0B86B);

  @override
  Widget build(BuildContext context) {
    if (result.status == ProfileAvailability.unknown) {
      return const SizedBox.shrink();
    }
    final servers = result.totalServers;
    final serversText = servers == null
        ? ''
        : '${result.workingServers ?? 0}/$servers';
    final (IconData? icon, Color color, String? text, String label) =
        switch (result.status) {
          ProfileAvailability.unknown => (null, Colors.white30, null, ''),
          ProfileAvailability.queued => (
            Icons.more_horiz_rounded,
            Colors.white38,
            null,
            'В очереди на проверку',
          ),
          ProfileAvailability.checking => (
            Icons.sync_rounded,
            NeuraUi.danger,
            null,
            'Проверяется',
          ),
          ProfileAvailability.available => (
            Icons.check_circle_outline_rounded,
            _good,
            [
              if (serversText.isNotEmpty) serversText,
              if (result.elapsedMs != null) '${result.elapsedMs} мс',
            ].join(' · '),
            servers == null
                ? 'Работает · ${result.elapsedMs ?? 0} мс'
                : 'Работают ${result.workingServers} из $servers серверов · '
                      'лучший ${result.elapsedMs ?? 0} мс',
          ),
          ProfileAvailability.unavailable when result.isTimeout => (
            Icons.timer_off_outlined,
            _bad,
            'таймаут',
            servers == null
                ? 'Не ответил вовремя'
                : 'Ни один из $servers серверов не ответил вовремя',
          ),
          ProfileAvailability.unavailable => (
            Icons.cancel_outlined,
            _bad,
            'не работает',
            servers == null
                ? 'Не работает: HTTPS через сервер не прошёл'
                : 'Не работает ни один из $servers серверов',
          ),
          ProfileAvailability.error => (
            Icons.error_outline_rounded,
            _warn,
            null,
            _errorLabel(result.code),
          ),
        };
    final time = result.checkedAt;
    final message = time == null
        ? label
        : '$label\nПроверено в '
              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final spinner =
        result.status == ProfileAvailability.checking &&
        !MediaQuery.disableAnimationsOf(context);
    return Tooltip(
      message: message,
      child: Semantics(
        label: message,
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 32, minHeight: 40),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (spinner)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.7,
                    color: NeuraUi.danger,
                  ),
                )
              else if (icon != null)
                Icon(icon, color: color, size: 18),
              if (text != null && text.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  text,
                  maxLines: 1,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _errorLabel(String? code) => switch (code) {
    'NO_NETWORK' || 'NO_NETWORK_DNS' => 'Нет доступной сети для проверки',
    'NETWORK_CHANGED' => 'Сеть изменилась. Повторите проверку',
    'NETWORK_BIND_FAILED' => 'Не удалось проверить вне текущего VPN',
    'INVALID_CONFIG' => 'Этот профиль нельзя проверить',
    'ENGINE_ERROR' => 'Ядро не приняло настройки сервера',
    'WORKER_TIMEOUT' || 'WORKER_STOPPED' || 'WORKER_UNAVAILABLE' =>
      'Проверка прервалась. Повторите позже',
    _ => 'Проверка не завершена. Повторите позже',
  };
}
