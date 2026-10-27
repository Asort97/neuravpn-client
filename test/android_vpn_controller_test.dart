import 'package:flutter_test/flutter_test.dart';
import 'package:happycat_vpnclient/services/android_vpn_controller.dart';

void main() {
  test('parses structured Android VPN runtime state', () {
    final status = AndroidVpnStatus.fromMap({
      'state': 'running',
      'sessionId': 'session-1',
      'updatedAt': 1720000000000,
      'routingMode': 'smart',
      'tx': 120,
      'rx': 340,
    });

    expect(status.phase, AndroidVpnPhase.running);
    expect(status.isRunning, isTrue);
    expect(status.isActive, isTrue);
    expect(status.sessionId, 'session-1');
    expect(status.routingMode, 'smart');
    expect(status.tx, 120);
    expect(status.rx, 340);
  });

  test('preserves structured Android VPN startup error', () {
    final status = AndroidVpnStatus.fromMap({
      'state': 'error',
      'errorCode': 'XRAY_CONFIG_REJECTED',
      'errorMessage': 'Конфигурация не поддерживается',
    });

    expect(status.phase, AndroidVpnPhase.error);
    expect(status.isActive, isFalse);
    expect(status.errorCode, 'XRAY_CONFIG_REJECTED');
    expect(status.errorMessage, 'Конфигурация не поддерживается');
  });
}
