import 'package:flutter/material.dart';

import '../services/profile_availability.dart';
import 'neura_ui.dart';

class ProfileAvailabilityIndicator extends StatelessWidget {
  const ProfileAvailabilityIndicator({super.key, required this.result});
  final ProfileCheckResult result;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (result.status) {
      ProfileAvailability.unknown => (
        Icons.horizontal_rule_rounded,
        Colors.white30,
        'Ещё не проверено',
      ),
      ProfileAvailability.queued => (
        Icons.more_horiz_rounded,
        Colors.white38,
        'В очереди',
      ),
      ProfileAvailability.checking => (
        Icons.sync_rounded,
        NeuraUi.danger,
        'Проверяется HTTPS',
      ),
      ProfileAvailability.available => (
        Icons.check_circle_outline_rounded,
        const Color(0xFF65C998),
        'HTTPS работает · ${result.elapsedMs ?? 0} мс',
      ),
      ProfileAvailability.unavailable => (
        Icons.cancel_outlined,
        NeuraUi.danger,
        result.code == 'TIMEOUT'
            ? 'HTTPS не ответил вовремя'
            : 'HTTPS не прошёл проверку',
      ),
      ProfileAvailability.error => (
        Icons.error_outline_rounded,
        const Color(0xFFE0B86B),
        _errorLabel(result.code),
      ),
    };
    final time = result.checkedAt;
    final message = time == null
        ? label
        : '$label\nПроверено в '
              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return Tooltip(
      message: message,
      child: Semantics(
        label: message,
        child: SizedBox(
          width: 32,
          height: 40,
          child: Center(
            child:
                result.status == ProfileAvailability.checking &&
                    !MediaQuery.disableAnimationsOf(context)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.7,
                      color: NeuraUi.danger,
                    ),
                  )
                : Icon(icon, color: color, size: 19),
          ),
        ),
      ),
    );
  }

  static String _errorLabel(String? code) => switch (code) {
    'NO_NETWORK' || 'NO_NETWORK_DNS' => 'Нет доступной сети для проверки',
    'NETWORK_CHANGED' => 'Сеть изменилась. Повторите проверку',
    'NETWORK_BIND_FAILED' => 'Не удалось проверить вне текущего VPN',
    'INVALID_CONFIG' ||
    'ENGINE_ERROR' => 'Не удалось запустить проверку конфигурации',
    _ => 'Проверка не завершена. Повторите позже',
  };
}
