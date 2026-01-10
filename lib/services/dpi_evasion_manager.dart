import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DpiEvasionManager {
  static const MethodChannel _channel = MethodChannel('happycat.vpn/dpi');

  Future<void> startNativeInjector(
    String serverIp,
    int serverPort, {
    required bool enableTcpWindowClamp,
    required bool enableSniRandomization,
  }) async {
    if (!Platform.isWindows) return;
    try {
      final ok = await _channel.invokeMethod<bool>('startTtlInjector', {
        'serverIp': serverIp,
        'serverPort': serverPort,
        'enableTcpWindowClamp': enableTcpWindowClamp,
        'enableSniRandomization': enableSniRandomization,
      });
      if (ok != true) {
        debugPrint('[DpiEvasionManager] startTtlInjector returned false');
      }
    } catch (_) {
      debugPrint('[DpiEvasionManager] startTtlInjector failed');
    }
  }

  Future<void> stopNativeInjector() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('stopTtlInjector');
    } catch (_) {
      debugPrint('[DpiEvasionManager] stopTtlInjector failed');
    }
  }

  Future<void> startForHost(
    String host,
    int serverPort, {
    required bool enableTcpWindowClamp,
    required bool enableSniRandomization,
  }) async {
    final ip = await _resolveIpv4(host);
    if (ip == null) return;
    await startNativeInjector(
      ip,
      serverPort,
      enableTcpWindowClamp: enableTcpWindowClamp,
      enableSniRandomization: enableSniRandomization,
    );
  }

  Future<String?> _resolveIpv4(String host) async {
    final parsedIp = InternetAddress.tryParse(host);
    if (parsedIp != null && parsedIp.type == InternetAddressType.IPv4) {
      return parsedIp.address;
    }

    try {
      final addresses = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 2));
      for (final address in addresses) {
        if (address.type == InternetAddressType.IPv4) {
          return address.address;
        }
      }
    } catch (_) {
      // ignore resolution failures
    }
    return null;
  }
}
